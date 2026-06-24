import 'package:flutter/material.dart';

import '../../domain/category.dart';
import '../../utils/html_utils.dart';

/// Expandable category row that works at arbitrary depth (avoids nested
/// [ExpansionTile] bugs where level 3+ stops responding to taps).
class CategoryTreeTile extends StatefulWidget {
  const CategoryTreeTile({
    super.key,
    required this.category,
    required this.onSelect,
    this.depth = 0,
    this.initiallyExpanded = false,
  });

  final Category category;
  final void Function(Category category) onSelect;
  final int depth;
  final bool initiallyExpanded;

  @override
  State<CategoryTreeTile> createState() => _CategoryTreeTileState();
}

class _CategoryTreeTileState extends State<CategoryTreeTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pad = 12.0 * widget.depth;
    final children = widget.category.children;
    final displayName =
        decodeHtmlEntities(categorySidebarLabel(widget.category));

    if (children.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(left: pad),
        child: ListTile(
          dense: widget.depth > 0,
          title: Text(displayName),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => widget.onSelect(widget.category),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: widget.depth > 0,
            title: Text(displayName),
            trailing: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 22,
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded) ...[
            ListTile(
              dense: true,
              leading: Icon(
                Icons.layers_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              title: Text('All in $displayName'),
              onTap: () => widget.onSelect(widget.category),
            ),
            ...children.map(
              (c) => CategoryTreeTile(
                category: c,
                depth: widget.depth + 1,
                onSelect: widget.onSelect,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
