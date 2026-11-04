// Expressive Code themes from re-cinq.com's --rc-code-* tokens. Hex values are required here, CSS vars don't reach Shiki.
import { ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';
const rcCode = {
	light: {
		background: '#f3f5ff',
		foreground: '#0b0b0b',
		comment: '#6e6e6e',
		keyword: '#6d28d9',
		function: '#0f766e',
		key: '#10207a',
		string: '#1b6b45',
		number: '#9a4a06',
		punctuation: '#55555f',
	},
	// Guess: the light palette lifted for contrast on the navy dark theme.
	dark: {
		background: '#0b1630',
		foreground: '#e6e8fd',
		comment: '#8c93b8',
		keyword: '#b9a4ff',
		function: '#5fd4c4',
		key: '#8f96f6',
		string: '#7fd6a2',
		number: '#f0a868',
		punctuation: '#a3a3a3',
	},
};

function codeTheme(type) {
	const palette = rcCode[type];
	const scope = (scopes, foreground, fontStyle) => ({ scope: scopes, settings: { foreground, ...(fontStyle && { fontStyle }) } });
	return new ExpressiveCodeTheme({
		name: `re-cinq-${type}`,
		type,
		colors: {
			'editor.background': palette.background,
			'editor.foreground': palette.foreground,
		},
		tokenColors: [
			scope(['comment', 'punctuation.definition.comment'], palette.comment, 'italic'),
			scope(['keyword', 'storage', 'storage.type', 'keyword.operator.word', 'constant.language'], palette.keyword),
			scope(['entity.name.function', 'support.function', 'meta.function-call', 'entity.name.tag'], palette.function),
			scope(['entity.name.tag.yaml', 'support.type.property-name', 'variable.other.property', 'entity.other.attribute-name', 'meta.object-literal.key'], palette.key),
			scope(['string', 'string.unquoted', 'markup.inline.raw'], palette.string),
			scope(['constant.numeric', 'constant.other', 'variable.other.constant'], palette.number),
			scope(['punctuation', 'meta.brace', 'keyword.operator'], palette.punctuation),
			scope(['variable', 'entity.name.type', 'support.type'], palette.foreground),
		],
	});
}

export const codeThemes = [codeTheme('dark'), codeTheme('light')];
