/**
 * Harbor Verifier — behavioral tests for autoPaths prototype-safety fix.
 *
 * These tests verify that Object.hasOwn() is used instead of the 'in' operator
 * for customPaths property checks. The 'in' operator checks the prototype chain,
 * so series slugs matching inherited properties (e.g., 'toString', 'constructor',
 * 'hasOwnProperty') would be incorrectly excluded from autoPaths routing.
 *
 * Each test exercises the real generateStaticParams functions under mocked
 * data, checking that the fix produces correct parameter arrays.
 */
import { describe, test, expect, mock, beforeAll, beforeEach, afterAll, afterEach } from 'bun:test';

// ─── Snapshot real modules (before any mocking) ──────────────────────────────
import * as realMarkdown from '../../src/lib/markdown';
import * as realUrls from '../../src/lib/urls';
const snapshotUrls = { ...realUrls };

let mockedPosts: Array<{ slug: string; series?: string; redirectFrom?: string[]; draft?: boolean }> = [];
let mockedNotes: Array<{ slug: string }> = [];
let mockedSeries: Record<string, Array<{ slug: string }>> = {};
let mockedPages: Array<{ slug: string }> = [];
let mockedSeriesData: Record<string, { title?: string } | null> = {};
const originalNodeEnv = process.env.NODE_ENV;

// ─── Next.js / component mocks (module-level, safe) ──────────────────────────
mock.module('next/navigation', () => ({
  notFound: () => { throw new Error('NOT_FOUND'); },
  redirect: () => { throw new Error('REDIRECT'); },
  usePathname: () => '/',
  useRouter: () => ({}),
  useSearchParams: () => new URLSearchParams(),
}));
mock.module('next/link', () => ({ default: 'a' }));
mock.module('next/image', () => ({ default: 'img' }));

mock.module('@/lib/i18n', () => ({
  t: (k: string) => k,
  tWith: (k: string) => k,
  resolveLocale: (v: unknown) =>
    typeof v === 'string' ? v : ((v as Record<string, string>)?.en ?? ''),
  useLanguage: () => ({ locale: 'en', setLocale: () => {} }),
}));

const Noop = { default: () => null };
mock.module('@/components/PageHeader', () => Noop);
mock.module('@/components/FlowContent', () => Noop);
mock.module('@/components/FlowHubTabs', () => Noop);
mock.module('@/components/NoteContent', () => Noop);
mock.module('@/components/FlowCalendarSidebar', () => Noop);
mock.module('@/components/MarkdownRenderer', () => Noop);
mock.module('@/components/Backlinks', () => Noop);
mock.module('@/components/ShareBar', () => Noop);
mock.module('@/components/CoverImage', () => Noop);
mock.module('@/components/SeriesCatalog', () => Noop);
mock.module('@/components/Pagination', () => Noop);
mock.module('@/components/PostList', () => Noop);
mock.module('@/components/PostCard', () => Noop);
mock.module('@/components/TagPageHeader', () => Noop);
mock.module('@/components/TagSidebar', () => Noop);
mock.module('@/components/TagContentTabs', () => Noop);
mock.module('@/components/Tag', () => Noop);
mock.module('@/components/AuthorStats', () => Noop);
mock.module('@/components/TranslatedText', () => Noop);
mock.module('@/components/NoteSidebar', () => Noop);
mock.module('@/components/Comments', () => Noop);
mock.module('@/layouts/PostLayout', () => Noop);
mock.module('@/layouts/SimpleLayout', () => Noop);
mock.module('@/layouts/BookLayout', () => Noop);
mock.module('@/components/RedirectPage', () => Noop);

// ─── Mock @/lib/markdown — deferred to beforeAll ─────────────────────────────
beforeAll(() => {
  mock.module('@/lib/markdown', () => ({
    getAllFlows: () => [],
    getAllNotes: () => mockedNotes,
    getAllPosts: () => mockedPosts.filter(p => !(process.env.NODE_ENV === 'production' && p.draft)),
    getAllBooks: () => [],
    getAllSeries: () => mockedSeries,
    getAllTags: () => ({}),
    getAllAuthors: () => ({}),
    getAllPages: () => mockedPages,
    getListingPosts: () => [],

    getFlowsByYear: () => [],
    getFlowsByMonth: () => [],
    getFlowBySlug: () => null,
    getFlowTags: () => ({}),
    getFlowsByTag: () => [],

    getNoteBySlug: () => null,
    getNoteTags: () => ({}),
    getNotesByTag: () => [],
    getAdjacentNotes: () => ({ prev: null, next: null }),
    getRecentNotes: () => [],

    getPostBySlug: (slug: string) => mockedPosts.find(p => p.slug === slug) ?? null,
    getRelatedPosts: () => [],
    getAdjacentPosts: () => ({ prev: null, next: null }),
    getPostsByTag: () => [],
    getPostsByAuthor: () => [],

    getBookData: () => null,
    getBookChapter: () => null,
    getBooksByAuthor: () => [],

    getSeriesData: (slug: string) => mockedSeriesData[slug] ?? null,
    getSeriesPosts: (slug: string) => mockedSeries[slug] ?? [],
    getSeriesAuthors: () => undefined,

    getAuthorSlug: (name: string) =>
      name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, ''),
    resolveAuthorParam: () => null,

    getAdjacentFlows: () => ({ prev: null, next: null }),
    buildSlugRegistry: () => new Map(),
    getBacklinks: () => [],
    getCollectionsForPost: () => [],
  }));
});

beforeEach(() => {
  mockedPosts = [];
  mockedNotes = [];
  mockedSeries = {};
  mockedPages = [];
  mockedSeriesData = {};
  process.env.NODE_ENV = originalNodeEnv;
});

afterEach(() => {
  mockedPosts = [];
  mockedNotes = [];
  mockedSeries = {};
  mockedPages = [];
  mockedSeriesData = {};
  process.env.NODE_ENV = originalNodeEnv;
});

// ─── Restore real modules ────────────────────────────────────────────────────
afterAll(() => {
  mock.module('@/lib/markdown', () => realMarkdown);
  mock.module('@/lib/urls', () => snapshotUrls);
});

// ═══════════════════════════════════════════════════════════════════════════════
// F2P Behavioral Tests
// ═══════════════════════════════════════════════════════════════════════════════

describe('F2P: autoPaths prototype safety (Object.hasOwn vs in operator)', () => {

  describe('[slug]/page — series listing route', () => {
    // Each test re-imports the module so it picks up the current mock state.

    test('includes series slug in autoPaths when customPaths is empty', async () => {
      // CustomPaths defaults to {} — autoPaths must still work.
      mockedSeries = { 'my-series': [{ slug: 'post-one' }] };
      mock.module('@/lib/urls', () => ({
        ...snapshotUrls,
        getSeriesAutoPaths: () => true,
        getSeriesCustomPaths: () => ({}),
        getPostUrl: (post: { slug: string; series?: string }) =>
          post.series ? `/${post.series}/${post.slug}` : `/posts/${post.slug}`,
        validateSeriesAutoPaths: () => {},
        RESERVED_ROUTE_SEGMENTS: snapshotUrls.RESERVED_ROUTE_SEGMENTS ?? new Set(),
        getPostsBasePath: snapshotUrls.getPostsBasePath,
        getPostsListUrl: snapshotUrls.getPostsListUrl,
        getPostsPageUrl: snapshotUrls.getPostsPageUrl,
        getSeriesListUrl: snapshotUrls.getSeriesListUrl,
      }));

      const { generateStaticParams } = await import('../../src/app/[slug]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: 'my-series' });
    });

    test('uses customPaths prefix (not series slug) when a custom path override exists', async () => {
      mockedSeries = { 'my-series': [{ slug: 'post-one' }] };
      mock.module('@/lib/urls', () => ({
        ...snapshotUrls,
        getSeriesAutoPaths: () => true,
        getSeriesCustomPaths: () => ({ 'my-series': 'articles' }),
        getPostUrl: (post: { slug: string; series?: string }) =>
          post.series === 'my-series' ? `/articles/${post.slug}` : `/posts/${post.slug}`,
        validateSeriesAutoPaths: () => {},
        RESERVED_ROUTE_SEGMENTS: snapshotUrls.RESERVED_ROUTE_SEGMENTS ?? new Set(),
        getPostsBasePath: snapshotUrls.getPostsBasePath,
        getPostsListUrl: snapshotUrls.getPostsListUrl,
        getPostsPageUrl: snapshotUrls.getPostsPageUrl,
        getSeriesListUrl: snapshotUrls.getSeriesListUrl,
      }));

      const { generateStaticParams } = await import('../../src/app/[slug]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: 'articles' });
      expect(params).not.toContainEqual({ slug: 'my-series' });
    });

    test('includes series slug matching Object.prototype inherited property name', async () => {
      // 'toString' is inherited from Object.prototype.
      // With the 'in' operator: 'toString' in {} → true (incorrect skip)
      // With Object.hasOwn: Object.hasOwn({}, 'toString') → false (correct include)
      mockedSeries = { 'toString': [{ slug: 'post-one' }] };
      mock.module('@/lib/urls', () => ({
        ...snapshotUrls,
        getSeriesAutoPaths: () => true,
        getSeriesCustomPaths: () => ({}),
        getPostUrl: (post: { slug: string; series?: string }) =>
          post.series ? `/${post.series}/${post.slug}` : `/posts/${post.slug}`,
        validateSeriesAutoPaths: () => {},
        RESERVED_ROUTE_SEGMENTS: snapshotUrls.RESERVED_ROUTE_SEGMENTS ?? new Set(),
        getPostsBasePath: snapshotUrls.getPostsBasePath,
        getPostsListUrl: snapshotUrls.getPostsListUrl,
        getPostsPageUrl: snapshotUrls.getPostsPageUrl,
        getSeriesListUrl: snapshotUrls.getSeriesListUrl,
      }));

      const { generateStaticParams } = await import('../../src/app/[slug]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: 'toString' });
    });

    test('includes series slug matching Object.prototype constructor property', async () => {
      // 'constructor' is inherited — must not be falsely matched by property check.
      mockedSeries = { 'constructor': [{ slug: 'post-one' }] };
      mock.module('@/lib/urls', () => ({
        ...snapshotUrls,
        getSeriesAutoPaths: () => true,
        getSeriesCustomPaths: () => ({}),
        getPostUrl: (post: { slug: string; series?: string }) =>
          post.series ? `/${post.series}/${post.slug}` : `/posts/${post.slug}`,
        validateSeriesAutoPaths: () => {},
        RESERVED_ROUTE_SEGMENTS: snapshotUrls.RESERVED_ROUTE_SEGMENTS ?? new Set(),
        getPostsBasePath: snapshotUrls.getPostsBasePath,
        getPostsListUrl: snapshotUrls.getPostsListUrl,
        getPostsPageUrl: snapshotUrls.getPostsPageUrl,
        getSeriesListUrl: snapshotUrls.getSeriesListUrl,
      }));

      const { generateStaticParams } = await import('../../src/app/[slug]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: 'constructor' });
    });

    test('includes Unicode series slug when autoPaths is enabled', async () => {
      mockedSeries = { '中文系列': [{ slug: 'post-one' }] };
      mock.module('@/lib/urls', () => ({
        ...snapshotUrls,
        getSeriesAutoPaths: () => true,
        getSeriesCustomPaths: () => ({}),
        getPostUrl: (post: { slug: string; series?: string }) =>
          post.series ? `/${post.series}/${post.slug}` : `/posts/${post.slug}`,
        validateSeriesAutoPaths: () => {},
        RESERVED_ROUTE_SEGMENTS: snapshotUrls.RESERVED_ROUTE_SEGMENTS ?? new Set(),
        getPostsBasePath: snapshotUrls.getPostsBasePath,
        getPostsListUrl: snapshotUrls.getPostsListUrl,
        getPostsPageUrl: snapshotUrls.getPostsPageUrl,
        getSeriesListUrl: snapshotUrls.getSeriesListUrl,
      }));

      const { generateStaticParams } = await import('../../src/app/[slug]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: '中文系列' });
    });

    test('throws when redirectFrom alias conflicts with RESERVED_ROUTE_SEGMENTS', async () => {
      mockedPosts = [{ slug: 'my-post', redirectFrom: ['/posts'] }];
      const { generateStaticParams } = await import('../../src/app/[slug]/page');
      expect(() => generateStaticParams()).toThrow('[amytis] redirectFrom "/posts"');
    });

    test('throws when two posts claim the same single-segment redirectFrom alias', async () => {
      mockedPosts = [
        { slug: 'post-a', redirectFrom: ['/duplicate'] },
        { slug: 'post-b', redirectFrom: ['/duplicate'] },
      ];
      const { generateStaticParams } = await import('../../src/app/[slug]/page');
      expect(() => generateStaticParams()).toThrow('[amytis] redirectFrom "/duplicate"');
    });
  });

  describe('[slug]/[postSlug] — post route', () => {
    test('prototype-safe autoPaths check in [slug]/[postSlug] page', async () => {
      // Set up autoPaths with series that has Object.prototype-matching name.
      mockedSeries = { 'toString': [{ slug: 'post-one' }] };
      mock.module('@/lib/urls', () => ({
        ...snapshotUrls,
        getSeriesAutoPaths: () => true,
        getSeriesCustomPaths: () => ({}),
        getPostUrl: (post: { slug: string; series?: string }) =>
          post.series ? `/${post.series}/${post.slug}` : `/posts/${post.slug}`,
        validateSeriesAutoPaths: () => {},
        RESERVED_ROUTE_SEGMENTS: snapshotUrls.RESERVED_ROUTE_SEGMENTS ?? new Set(),
        getPostsBasePath: snapshotUrls.getPostsBasePath,
        getPostsListUrl: snapshotUrls.getPostsListUrl,
        getPostsPageUrl: snapshotUrls.getPostsPageUrl,
        getSeriesListUrl: snapshotUrls.getSeriesListUrl,
        getStaticPageUrl: snapshotUrls.getStaticPageUrl,
        getBookUrl: snapshotUrls.getBookUrl,
        getBookChapterUrl: snapshotUrls.getBookChapterUrl,
        getFlowUrl: snapshotUrls.getFlowUrl,
        getPostUrlInCollection: snapshotUrls.getPostUrlInCollection,
        getBooksListUrl: snapshotUrls.getBooksListUrl,
      }));

      const { generateStaticParams } = await import('../../src/app/[slug]/[postSlug]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: 'toString', postSlug: 'post-one' });
    });

    test('includes encoded Unicode postSlug variants via redirectFrom in development', async () => {
      mockedPosts = [{ slug: 'my-post', redirectFrom: ['/old-prefix/中文文章'] }];
      process.env.NODE_ENV = 'development';
      const { generateStaticParams } = await import('../../src/app/[slug]/[postSlug]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: 'old-prefix', postSlug: '中文文章' });
      expect(params).toContainEqual({ slug: 'old-prefix', postSlug: encodeURIComponent('中文文章') });
    });

    test('does not include encoded Unicode postSlug variants in production', async () => {
      mockedPosts = [{ slug: 'my-post', redirectFrom: ['/old-prefix/中文文章'] }];
      process.env.NODE_ENV = 'production';
      const { generateStaticParams } = await import('../../src/app/[slug]/[postSlug]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: 'old-prefix', postSlug: '中文文章' });
      expect(params).not.toContainEqual({ slug: 'old-prefix', postSlug: encodeURIComponent('中文文章') });
    });
  });

  describe('[slug]/page/[page] — paginated series listing', () => {
    test('prototype-safe autoPaths check in paginated route', async () => {
      // Series with many posts (enough for page 2+).
      const posts = Array.from({ length: 20 }, (_, i) => ({ slug: `post-${i}` }));
      mockedSeries = { 'toString': posts };
      mock.module('@/lib/urls', () => ({
        ...snapshotUrls,
        getSeriesAutoPaths: () => true,
        getSeriesCustomPaths: () => ({}),
        getPostUrl: (post: { slug: string; series?: string }) =>
          post.series ? `/${post.series}/${post.slug}` : `/posts/${post.slug}`,
        validateSeriesAutoPaths: () => {},
        RESERVED_ROUTE_SEGMENTS: snapshotUrls.RESERVED_ROUTE_SEGMENTS ?? new Set(),
        getPostsBasePath: snapshotUrls.getPostsBasePath,
        getPostsListUrl: snapshotUrls.getPostsListUrl,
        getPostsPageUrl: snapshotUrls.getPostsPageUrl,
        getSeriesListUrl: snapshotUrls.getSeriesListUrl,
        getStaticPageUrl: snapshotUrls.getStaticPageUrl,
      }));

      const { generateStaticParams } = await import('../../src/app/[slug]/page/[page]/page');
      const params = await generateStaticParams();
      // Should include page 2 for the 'toString' series (which has 20 posts).
      expect(params).toContainEqual({ slug: 'toString', page: '2' });
    });

    test('customPaths override prevents autoPaths in paginated route', async () => {
      const posts = Array.from({ length: 20 }, (_, i) => ({ slug: `post-${i}` }));
      mockedSeries = { 'my-series': posts };
      mock.module('@/lib/urls', () => ({
        ...snapshotUrls,
        getSeriesAutoPaths: () => true,
        getSeriesCustomPaths: () => ({ 'my-series': 'articles' }),
        getPostUrl: (post: { slug: string; series?: string }) =>
          post.series === 'my-series' ? `/articles/${post.slug}` : `/posts/${post.slug}`,
        validateSeriesAutoPaths: () => {},
        RESERVED_ROUTE_SEGMENTS: snapshotUrls.RESERVED_ROUTE_SEGMENTS ?? new Set(),
        getPostsBasePath: snapshotUrls.getPostsBasePath,
        getPostsListUrl: snapshotUrls.getPostsListUrl,
        getPostsPageUrl: snapshotUrls.getPostsPageUrl,
        getSeriesListUrl: snapshotUrls.getSeriesListUrl,
        getStaticPageUrl: snapshotUrls.getStaticPageUrl,
      }));

      const { generateStaticParams } = await import('../../src/app/[slug]/page/[page]/page');
      const params = await generateStaticParams();
      expect(params).toContainEqual({ slug: 'articles', page: '2' });
      expect(params).not.toContainEqual({ slug: 'my-series', page: '2' });
    });
  });
});
