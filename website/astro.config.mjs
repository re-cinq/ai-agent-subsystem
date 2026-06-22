// @ts-check
import { defineConfig } from 'astro/config';
import mermaid from 'astro-mermaid';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	// GitHub's new isolated Pages domains serve project sites at the domain root,
	// so there is no repo-name base path.
	site: 'https://glowing-garbanzo-y7ek98q.pages.github.io',
	integrations: [
		// astro-mermaid must be registered before starlight so its remark/rehype
		// transforms wrap the ```mermaid fenced blocks before Starlight renders them.
		mermaid({
			theme: 'default',
			autoTheme: true,
		}),
		starlight({
			title: 'AI agent subsystem',
			description:
				'Run autonomous coding agents as Kubernetes resources: declarative recipes, reusable runtimes, and a reconciling controller.',
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/re-cinq/ai-agent-subsystem',
				},
			],
			customCss: ['./src/styles/custom.css'],
			sidebar: [
				{
					label: 'Concepts',
					items: [
						{ label: 'Overview', slug: 'concepts/overview' },
						{ label: 'How the pieces relate', slug: 'concepts/relationships' },
						{ label: 'Architecture', slug: 'concepts/architecture' },
						{ label: 'AgentDefinition', slug: 'concepts/agentdefinition' },
						{ label: 'Station', slug: 'concepts/station' },
						{ label: 'Agent', slug: 'concepts/agent' },
						{ label: 'Controller lifecycle', slug: 'concepts/controller-lifecycle' },
						{ label: 'Agent runtime', slug: 'concepts/agent-runtime' },
					],
				},
				{
					label: 'Setup',
					items: [
						{ label: 'Prerequisites', slug: 'setup/prerequisites' },
						{ label: 'Local cluster', slug: 'setup/local-cluster' },
						{ label: 'Install', slug: 'setup/install' },
					],
				},
				{
					label: 'Tasks',
					items: [
						{ label: 'Define a recipe', slug: 'tasks/define-a-recipe' },
						{ label: 'Create a station', slug: 'tasks/create-a-station' },
						{ label: 'Launch an agent', slug: 'tasks/launch-an-agent' },
						{ label: 'Setting limits', slug: 'tasks/set-limits' },
						{ label: 'Collect output', slug: 'tasks/collect-output' },
						{ label: 'Examples', slug: 'tasks/examples' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ label: 'AgentDefinition CRD', slug: 'reference/crd-agentdefinition' },
						{ label: 'Station CRD', slug: 'reference/crd-station' },
						{ label: 'Agent CRD', slug: 'reference/crd-agent' },
						{ label: 'Prompt templating', slug: 'reference/prompt-templating' },
						{ label: 'RBAC & network', slug: 'reference/rbac-and-network' },
					],
				},
				{
					label: 'Contribute',
					items: [
						{ label: 'Repository layout', slug: 'contribute/repo-layout' },
						{ label: 'Building', slug: 'contribute/building' },
						{ label: 'Roadmap', slug: 'contribute/roadmap' },
					],
				},
			],
		}),
	],
});
