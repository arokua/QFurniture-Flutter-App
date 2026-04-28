import 'package:flutter/material.dart';

import '../data/category_repository.dart';
import '../domain/category.dart';
import '../utils/html_utils.dart';

/// Full-screen modal category tree: tap a category to apply the filter [onSelected(name)].
Future<void> showCategoryPickerSheet(
  BuildContext context, {
  required void Function(String? categoryName) onSelected,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.94,
        builder: (context, scrollController) {
          return _CategoryPickerBody(
            scrollController: scrollController,
            onSelected: onSelected,
          );
        },
      );
    },
  );
}

class _CategoryPickerBody extends StatefulWidget {
  const _CategoryPickerBody({
    required this.scrollController,
    required this.onSelected,
  });

  final ScrollController scrollController;
  final void Function(String? categoryName) onSelected;

  @override
  State<_CategoryPickerBody> createState() => _CategoryPickerBodyState();
}

class _CategoryPickerBodyState extends State<_CategoryPickerBody> {
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

  void _pick(Category c) {
    widget.onSelected(c.name);
    Navigator.of(context).pop();
  }

  void _clear() {
    widget.onSelected(null);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            'Categories',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ListTile(
          leading: Icon(Icons.clear_all_rounded, color: theme.colorScheme.primary),
          title: const Text('All products'),
          subtitle: const Text('Clear category filter'),
          onTap: _clear,
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            controller: widget.scrollController,
            padding: const EdgeInsets.only(bottom: 24),
            children: _roots
                .map(
                  (c) => _CategoryTreeNode(
                    category: c,
                    depth: 0,
                    onSelect: _pick,
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _CategoryTreeNode extends StatelessWidget {
  const _CategoryTreeNode({
    required this.category,
    required this.depth,
    required this.onSelect,
  });

  final Category category;
  final int depth;
  final void Function(Category) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pad = 12.0 * depth;
    final children = category.children;
    final displayName = decodeHtmlEntities(categorySidebarLabel(category));

    if (children.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(left: pad),
        child: ListTile(
          dense: depth > 0,
          title: Text(displayName),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => onSelect(category),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: pad),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey('cat_${category.id}'),
          title: Text(displayName),
          children: [
            ListTile(
              dense: true,
              leading: Icon(Icons.layers_outlined, size: 20, color: theme.colorScheme.primary),
              title: Text('All in $displayName'),
              onTap: () => onSelect(category),
            ),
            ...children.map(
              (c) => _CategoryTreeNode(
                category: c,
                depth: depth + 1,
                onSelect: onSelect,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
