// The Swizzle documentation site — swizzle.nerdmenot.in
//
// Same shape as decoy's site, deliberately: Starlight owns `src/content/docs/**` and
// nothing else, and the landing page is a plain Astro route with its own layout. A docs
// framework's default shell is the fastest way to make a project look like every other
// project, and the two sibling libraries should look related to each other rather than
// to the framework.
//
// What Starlight is genuinely better at, and is kept for: sidebar, search, keyboard
// navigation, heading anchors, and accessibility on the reference pages.
import { defineConfig } from 'astro/config'
import starlight from '@astrojs/starlight'

export default defineConfig({
  site: 'https://swizzle.nerdmenot.in',
  integrations: [
    starlight({
      title: 'Swizzle',
      description:
        'Migrations, a typed query builder and codegen for Postgres, MySQL/MariaDB and ' +
        'SQLite, in one Swift package. A query builder, not an ORM.',
      logo: { src: './src/assets/icon.svg', alt: 'Swizzle', replacesTitle: false },
      favicon: '/icon.svg',
      customCss: ['./src/styles/theme.css'],
      // Code reads as a terminal in both site themes. A light syntax theme on warm paper
      // washes out to near-invisible, and switching themes mid-scroll is worse than
      // committing to one.
      expressiveCode: {
        themes: ['github-dark'],
        styleOverrides: {
          borderRadius: '3px',
          borderColor: 'transparent',
          codeFontFamily: 'var(--swz-mono)',
        },
      },
      components: {
        Header: './src/components/Header.astro',
        PageTitle: './src/components/PageTitle.astro',
      },
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/nerdmenot-swift/swizzle' },
      ],
      editLink: { baseUrl: 'https://github.com/nerdmenot-swift/swizzle/edit/main/website/' },
      lastUpdated: true,
      pagination: true,
      head: [
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' } },
        {
          tag: 'link',
          attrs: { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: true },
        },
        {
          tag: 'link',
          attrs: {
            rel: 'stylesheet',
            href:
              'https://fonts.googleapis.com/css2?' +
              'family=Public+Sans:wght@400;500;600;700&' +
              'family=IBM+Plex+Mono:wght@400;500;600&display=swap',
          },
        },
      ],
      sidebar: [
        {
          label: 'Start',
          items: [{ slug: 'start/install' }, { slug: 'start/quick-start' }],
        },
        {
          label: 'Guides',
          items: [
            { slug: 'guides/migrations' },
            { slug: 'guides/querying' },
            { slug: 'guides/codegen' },
            { slug: 'guides/streaming' },
          ],
        },
        {
          label: 'Reference',
          items: [{ slug: 'reference/cli' }, { slug: 'reference/dialects' }],
        },
      ],
    }),
  ],
})
