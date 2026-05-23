import type { NodePath, PluginObj, types as t } from '@babel/core';

const DOCS_URL = 'https://github.com/unbogify/react-native-video-pipeline#worklet-directives';

interface Target {
  /** Index of the argument carrying the options object. */
  argIndex: number;
  /** Property name within the options object whose value must be a worklet. */
  propName: string;
  /** Human-readable callsite, used in error messages. */
  label: string;
}

const TARGETS: Record<string, Record<string, Target>> = {
  Video: {
    compose: { argIndex: 1, propName: 'drawFrame', label: 'Video.compose' },
    synthesize: { argIndex: 0, propName: 'drawFrame', label: 'Video.synthesize' },
  },
};

function matchTarget(callee: t.Expression | t.V8IntrinsicIdentifier | t.Super): Target | null {
  if (callee.type !== 'MemberExpression') return null;
  if (callee.computed) return null;
  const obj = callee.object;
  const prop = callee.property;
  if (obj.type !== 'Identifier') return null;
  if (prop.type !== 'Identifier') return null;
  return TARGETS[obj.name]?.[prop.name] ?? null;
}

function findValueProperty(
  obj: t.ObjectExpression,
  name: string,
): t.ObjectProperty | t.ObjectMethod | null {
  for (const p of obj.properties) {
    if (p.type === 'ObjectProperty' || p.type === 'ObjectMethod') {
      if (p.computed) continue;
      const key = p.key;
      if (key.type === 'Identifier' && key.name === name) return p;
      if (key.type === 'StringLiteral' && key.value === name) return p;
    }
  }
  return null;
}

function hasWorkletDirective(body: t.BlockStatement): boolean {
  for (const d of body.directives) {
    if (d.value.value === 'worklet') return true;
  }
  return false;
}

export default function babelPluginVideoPipeline(): PluginObj {
  return {
    name: 'babel-plugin-video-pipeline',
    visitor: {
      CallExpression(path: NodePath<t.CallExpression>) {
        const target = matchTarget(path.node.callee);
        if (!target) return;
        const arg = path.node.arguments[target.argIndex];
        if (!arg || arg.type !== 'ObjectExpression') return;
        const prop = findValueProperty(arg, target.propName);
        if (!prop) return;

        if (prop.type === 'ObjectMethod') {
          // `{ drawFrame() { ... } }` desugars to a function literal.
          if (hasWorkletDirective(prop.body)) return;
          throw path.buildCodeFrameError(workletError(target));
        }

        const value = prop.value;
        if (value.type !== 'ArrowFunctionExpression' && value.type !== 'FunctionExpression') {
          // Named identifier, member expression, etc. — caller's responsibility.
          return;
        }
        if (value.body.type !== 'BlockStatement') {
          // `() => expr` — no place to put a directive.
          throw path.buildCodeFrameError(workletError(target));
        }
        if (hasWorkletDirective(value.body)) return;
        throw path.buildCodeFrameError(workletError(target));
      },
    },
  };
}

function workletError(target: Target): string {
  return (
    `${target.label}: the \`${target.propName}\` callback is a function literal but does not begin ` +
    `with a "'worklet';" directive. Add \`'worklet';\` as the first statement of the function body, ` +
    `or pass a named identifier instead. See ${DOCS_URL}`
  );
}
