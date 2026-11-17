import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

/* ============================================================
 *  DAILY DIGEST — a small news reader
 *  Layers: Model → Repository → Controller (Provider) → UI
 * ============================================================ */

// ------------------------------------------------------------
// MODEL
// ------------------------------------------------------------

class Post {
  final int id;
  final int authorId;
  final String headline;
  final String content;

  const Post({
    required this.id,
    required this.authorId,
    required this.headline,
    required this.content,
  });

  factory Post.fromMap(Map<String, dynamic> map) => Post(
    id: map['id'] as int,
    authorId: map['userId'] as int,
    headline: (map['title'] as String?) ?? '',
    content: (map['body'] as String?) ?? '',
  );

  /// First letter of the headline, used for the monogram badge.
  String get initial => headline.isEmpty ? '?' : headline[0].toUpperCase();

  /// Rough reading time (200 words per minute, at least 1 minute).
  int get readMinutes {
    final words = content.split(RegExp(r'\s+')).length;
    return (words / 200).ceil().clamp(1, 99);
  }
}

/// Gives every post its own stable accent colour based on its id.
Color accentFor(int seed, {double lightness = 0.5}) {
  final hue = (seed * 47) % 360;
  return HSLColor.fromAHSL(1, hue.toDouble(), 0.55, lightness).toColor();
}

// ------------------------------------------------------------
// REPOSITORY (REST API)
// ------------------------------------------------------------

class PostRepository {
  static const _endpoint = 'https://jsonplaceholder.typicode.com/posts';
  final http.Client _client;

  PostRepository({http.Client? client}) : _client = client ?? http.Client();

  Future<List<Post>> getPosts() async {
    final res = await _client
        .get(Uri.parse(_endpoint))
        .timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw Exception('Server responded with ${res.statusCode}');
    }

    final decoded = jsonDecode(res.body) as List<dynamic>;
    return decoded.map((e) => Post.fromMap(e as Map<String, dynamic>)).toList();
  }
}

// ------------------------------------------------------------
// CONTROLLER (STATE MANAGEMENT WITH PROVIDER)
// ------------------------------------------------------------

enum LoadStatus { idle, loading, success, failure }

enum SortOrder { oldest, newest, alphabetical }

class PostController extends ChangeNotifier {
  PostController(this._repo);

  final PostRepository _repo;

  LoadStatus _status = LoadStatus.idle;
  List<Post> _all = [];
  final Set<int> _savedIds = {};
  String _query = '';
  SortOrder _sort = SortOrder.oldest;
  String? _errorMessage;
  Timer? _debounce;

  LoadStatus get status => _status;
  String? get errorMessage => _errorMessage;
  String get query => _query;
  SortOrder get sort => _sort;
  int get totalCount => _all.length;
  int get savedCount => _savedIds.length;

  bool isSaved(int id) => _savedIds.contains(id);

  /// Posts after search + sort are applied.
  List<Post> get visiblePosts {
    final q = _query.trim().toLowerCase();
    final list = _all
        .where((p) => q.isEmpty || p.headline.toLowerCase().contains(q))
        .toList();

    switch (_sort) {
      case SortOrder.oldest:
        list.sort((a, b) => a.id.compareTo(b.id));
        break;
      case SortOrder.newest:
        list.sort((a, b) => b.id.compareTo(a.id));
        break;
      case SortOrder.alphabetical:
        list.sort((a, b) => a.headline.compareTo(b.headline));
        break;
    }
    return list;
  }

  List<Post> get savedPosts =>
      _all.where((p) => _savedIds.contains(p.id)).toList();

  Future<void> load() async {
    final firstLoad = _all.isEmpty;
    if (firstLoad) {
      _status = LoadStatus.loading;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      _all = await _repo.getPosts();
      _status = LoadStatus.success;
      _errorMessage = null;
    } catch (_) {
      _errorMessage = 'Couldn\'t reach the server.\nCheck your connection.';
      // Keep old data on a failed refresh; only show the error screen
      // when there is nothing to display.
      _status = firstLoad ? LoadStatus.failure : LoadStatus.success;
    }
    notifyListeners();
  }

  /// Search with a short debounce so we don't rebuild on every keystroke.
  void search(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _query = text;
      notifyListeners();
    });
  }

  void clearSearch() {
    _debounce?.cancel();
    _query = '';
    notifyListeners();
  }

  void changeSort(SortOrder order) {
    _sort = order;
    notifyListeners();
  }

  void toggleSave(int id) {
    _savedIds.contains(id) ? _savedIds.remove(id) : _savedIds.add(id);
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

// ------------------------------------------------------------
// ENTRY POINT
// ------------------------------------------------------------

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => PostController(PostRepository())..load(),
      child: const DigestApp(),
    ),
  );
}

class DigestApp extends StatelessWidget {
  const DigestApp({super.key});

  static const _seed = Color(0xFF00897B); // teal

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Daily Digest',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeShell(),
    );
  }
}

// ------------------------------------------------------------
// HOME SHELL (bottom navigation: Feed / Saved)
// ------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final savedCount = context.select<PostController, int>((c) => c.savedCount);

    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [FeedPage(), SavedPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.newspaper_outlined),
            selectedIcon: Icon(Icons.newspaper),
            label: 'Feed',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: savedCount > 0,
              label: Text('$savedCount'),
              child: const Icon(Icons.bookmarks_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: savedCount > 0,
              label: Text('$savedCount'),
              child: const Icon(Icons.bookmarks),
            ),
            label: 'Saved',
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------
// FEED PAGE
// ------------------------------------------------------------

class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<PostController>();
    final posts = c.visiblePosts;
    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: c.load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar.medium(
            title: const Text('Daily Digest'),
            actions: [
              PopupMenuButton<SortOrder>(
                tooltip: 'Sort',
                icon: const Icon(Icons.swap_vert),
                initialValue: c.sort,
                onSelected: c.changeSort,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: SortOrder.oldest,
                    child: Text('Oldest first'),
                  ),
                  PopupMenuItem(
                    value: SortOrder.newest,
                    child: Text('Newest first'),
                  ),
                  PopupMenuItem(
                    value: SortOrder.alphabetical,
                    child: Text('A → Z'),
                  ),
                ],
              ),
              const SizedBox(width: 4),
            ],
          ),

          // Search bar
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SearchBar(
                controller: _searchCtrl,
                hintText: 'Find a story…',
                elevation: const MaterialStatePropertyAll(0),
                leading: const Icon(Icons.search),
                onChanged: c.search,
                trailing: [
                  if (c.query.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchCtrl.clear();
                        c.clearSearch();
                      },
                    ),
                ],
              ),
            ),
          ),

          // Result counter
          if (c.status == LoadStatus.success)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  'Showing ${posts.length} of ${c.totalCount} stories',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),

          // Body
          if (c.status == LoadStatus.loading || c.status == LoadStatus.idle)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (c.status == LoadStatus.failure)
            SliverFillRemaining(
              hasScrollBody: false,
              child: StatusView(
                icon: Icons.cloud_off_rounded,
                title: 'Something went wrong',
                message: c.errorMessage ?? '',
                actionLabel: 'Try again',
                onAction: c.load,
              ),
            )
          else if (posts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: StatusView(
                icon: Icons.manage_search_rounded,
                title: 'No matches',
                message: 'Nothing found for "${c.query}".',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 16),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) =>
                      PostCard(post: posts[i], heroTag: 'feed-${posts[i].id}'),
                  childCount: posts.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------
// SAVED PAGE (swipe to remove, with undo)
// ------------------------------------------------------------

class SavedPage extends StatelessWidget {
  const SavedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<PostController>();
    final saved = c.savedPosts;

    return CustomScrollView(
      slivers: [
        const SliverAppBar.medium(title: Text('Saved for later')),
        if (saved.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: StatusView(
              icon: Icons.bookmark_add_outlined,
              title: 'Your reading list is empty',
              message: 'Tap the bookmark on any story to keep it here.',
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate((context, i) {
              final post = saved[i];
              return Dismissible(
                key: ValueKey('saved-${post.id}'),
                direction: DismissDirection.endToStart,
                background: const _SwipeBackground(),
                onDismissed: (_) {
                  final messenger = ScaffoldMessenger.of(context);
                  c.toggleSave(post.id);
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: const Text('Removed from saved'),
                        action: SnackBarAction(
                          label: 'UNDO',
                          onPressed: () => c.toggleSave(post.id),
                        ),
                      ),
                    );
                },
                child: PostCard(post: post, heroTag: 'saved-${post.id}'),
              );
            }, childCount: saved.length),
          ),
      ],
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.only(right: 24),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(Icons.delete_sweep_rounded, color: scheme.onErrorContainer),
    );
  }
}

// ------------------------------------------------------------
// REUSABLE WIDGETS
// ------------------------------------------------------------

class PostCard extends StatelessWidget {
  const PostCard({super.key, required this.post, required this.heroTag});

  final Post post;
  final String heroTag;

  void _open(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, __, ___) =>
            PostDetailPage(post: post, heroTag: heroTag),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: InkWell(
          onTap: () => _open(context),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Hero(
                      tag: heroTag,
                      child: Monogram(post: post, size: 44),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Author ${post.authorId}',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: scheme.primary,
                            ),
                          ),
                          Text(
                            '${post.readMinutes} min read  •  #${post.id}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SaveButton(postId: post.id),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  post.headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  post.content.replaceAll('\n', ' '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded-square badge with the headline's first letter on a gradient.
class Monogram extends StatelessWidget {
  const Monogram({super.key, required this.post, required this.size});

  final Post post;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.32),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accentFor(post.id, lightness: 0.6),
              accentFor(post.id, lightness: 0.4),
            ],
          ),
        ),
        child: Text(
          post.initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.45,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// Bookmark toggle with a small pop animation.
class SaveButton extends StatelessWidget {
  const SaveButton({super.key, required this.postId});

  final int postId;

  @override
  Widget build(BuildContext context) {
    final saved = context.select<PostController, bool>(
      (c) => c.isSaved(postId),
    );
    final scheme = Theme.of(context).colorScheme;

    return IconButton(
      tooltip: saved ? 'Remove bookmark' : 'Save for later',
      onPressed: () => context.read<PostController>().toggleSave(postId),
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: child),
        child: Icon(
          saved ? Icons.bookmark : Icons.bookmark_border,
          key: ValueKey(saved),
          color: saved ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Shared view for loading errors and empty states.
class StatusView extends StatelessWidget {
  const StatusView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Icon(
              icon,
              size: 40,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------
// DETAIL PAGE
// ------------------------------------------------------------

class PostDetailPage extends StatelessWidget {
  const PostDetailPage({super.key, required this.post, required this.heroTag});

  final Post post;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = context.select<PostController, bool>(
      (c) => c.isSaved(post.id),
    );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 220,
            foregroundColor: Colors.white,
            backgroundColor: accentFor(post.id, lightness: 0.4),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      accentFor(post.id, lightness: 0.55),
                      accentFor(post.id, lightness: 0.3),
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Center(
                    child: Hero(
                      tag: heroTag,
                      child: Monogram(post: post, size: 88),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        avatar: const Icon(Icons.person_outline, size: 18),
                        label: Text('Author ${post.authorId}'),
                      ),
                      Chip(
                        avatar: const Icon(Icons.schedule, size: 18),
                        label: Text('${post.readMinutes} min read'),
                      ),
                      Chip(label: Text('Story #${post.id}')),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    post.headline,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 16),
                  Text(
                    post.content,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          context.read<PostController>().toggleSave(post.id);
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text(saved ? 'Removed from saved' : 'Saved for later'),
              ),
            );
        },
        icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add_outlined),
        label: Text(saved ? 'Saved' : 'Save'),
      ),
    );
  }
}
