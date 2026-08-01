import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_router.dart';
import '../services/auth_service.dart';
import '../features/catalog/data/category_repository.dart';
import '../features/catalog/domain/category.dart';
import '../features/catalog/domain/category_filter.dart';
import '../features/catalog/providers/category_providers.dart';
import '../features/catalog/presentation/widgets/category_tree_tile.dart';
import '../utils/user_facing_errors.dart';

/// Categories tab: fetch from Store API, build tree (parent/children), display.
/// Tap category -> filter catalog and switch to Catalog tab.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final _repo = CategoryRepository();
  List<Category> _roots = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final roots = await _repo.getCategoryTree();
      if (mounted) {
        setState(() {
          _roots = roots;
          _loading = false;
        });
      }
    } catch (e, st) {
      debugPrint('Categories load error: $e\n$st');
      if (mounted) {
        setState(() {
          _error = userFacingCatalogError(e);
          _loading = false;
        });
      }
    }
  }

  void _onCategoryTap(BuildContext context, Category category) {
    final container = ProviderScope.containerOf(context);
    container.read(selectedCategoryProvider.notifier).state =
        SelectedCategory(id: category.id, name: category.name);
    context.go(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService.instance.isSignedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('Categories')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Sign in to browse categories and the full catalogue.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => context.push(AppRoutes.login),
                  child: const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Categories')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        elevation: 0,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _roots.length,
        itemBuilder: (context, index) {
          final parent = _roots[index];
          return CategoryTreeTile(
            category: parent,
            onSelect: (c) => _onCategoryTap(context, c),
          );
        },
      ),
    );
  }
}
