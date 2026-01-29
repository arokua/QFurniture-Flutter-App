import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_router.dart';
import '../features/catalog/data/category_repository.dart';
import '../features/catalog/domain/category.dart';
import '../features/catalog/presentation/product_list_screen.dart';

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
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _onCategoryTap(BuildContext context, Category category) {
    ProviderScope.containerOf(context).read(selectedCategoryProvider.notifier).state = category.name;
    context.go(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
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
          return _CategoryTile(
            category: parent,
            onTap: () => _onCategoryTap(context, parent),
            children: parent.children,
            onChildTap: (child) => _onCategoryTap(context, child),
          );
        },
      ),
    );
  }
}

class _CategoryTile extends StatefulWidget {
  const _CategoryTile({
    required this.category,
    required this.onTap,
    required this.children,
    required this.onChildTap,
  });

  final Category category;
  final VoidCallback onTap;
  final List<Category> children;
  final void Function(Category) onChildTap;

  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hasChildren = widget.children.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(widget.category.name),
          trailing: hasChildren
              ? Icon(_expanded ? Icons.expand_less : Icons.expand_more)
              : const Icon(Icons.chevron_right, size: 20),
          onTap: () {
            if (hasChildren) {
              setState(() => _expanded = !_expanded);
            } else {
              widget.onTap();
            }
          },
        ),
        if (hasChildren && _expanded)
          ...widget.children.map(
            (child) => Padding(
              padding: const EdgeInsets.only(left: 24),
              child: ListTile(
                title: Text(child.name),
                onTap: () => widget.onChildTap(child),
              ),
            ),
          ),
      ],
    );
  }
}
