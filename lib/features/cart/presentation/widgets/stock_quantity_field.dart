import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Quantity stepper with a centered numeric field. When [stockCeiling] is set,
/// values cannot exceed it (live while typing and on blur).
class StockQuantityField extends StatefulWidget {
  const StockQuantityField({
    super.key,
    required this.quantity,
    required this.onChanged,
    this.stockCeiling,
    this.minQuantity = 1,
  });

  final int quantity;
  final ValueChanged<int> onChanged;

  /// Known stock count from catalogue; `null` = no numeric cap (still min [minQuantity]).
  final int? stockCeiling;
  final int minQuantity;

  @override
  State<StockQuantityField> createState() => _StockQuantityFieldState();
}

class _StockQuantityFieldState extends State<StockQuantityField> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  int get _effectiveMax =>
      widget.stockCeiling ?? 999999;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.quantity}');
    _focus = FocusNode();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(StockQuantityField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.quantity != widget.quantity && !_focus.hasFocus) {
      _controller.text = '${widget.quantity}';
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      _controller.text = '${widget.quantity}';
      return;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      _controller.text = '${widget.quantity}';
      return;
    }
    final clamped =
        parsed.clamp(widget.minQuantity, _effectiveMax).toInt();
    if (clamped != parsed) {
      _controller.text = '$clamped';
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    }
    if (clamped != widget.quantity) {
      widget.onChanged(clamped);
    }
  }

  void _applyDelta(int delta) {
    final next = (widget.quantity + delta)
        .clamp(widget.minQuantity, _effectiveMax)
        .toInt();
    if (next != widget.quantity) {
      widget.onChanged(next);
      _controller.text = '$next';
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxKnown = widget.stockCeiling;
    final atMax = maxKnown != null && widget.quantity >= maxKnown;
    final atMin = widget.quantity <= widget.minQuantity;

    return Row(
      children: [
        IconButton.filledTonal(
          iconSize: 20,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: atMin ? null : () => _applyDelta(-1),
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 72,
          height: 40,
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            textInputAction: TextInputAction.done,
            maxLines: 1,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              if (maxKnown != null) _MaxIntFormatter(maxKnown),
            ],
            onSubmitted: (_) {
              _focus.unfocus();
              _commit();
            },
            onTapOutside: (_) {
              _focus.unfocus();
            },
          ),
        ),
        IconButton.filledTonal(
          iconSize: 20,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: atMax ? null : () => _applyDelta(1),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

/// Keeps parsed integer from exceeding [max] while typing (e.g. max 5 blocks "6").
class _MaxIntFormatter extends TextInputFormatter {
  _MaxIntFormatter(this.max);
  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    final n = int.tryParse(newValue.text);
    if (n == null) return oldValue;
    if (n > max) {
      final s = '$max';
      return TextEditingValue(
        text: s,
        selection: TextSelection.collapsed(offset: s.length),
      );
    }
    return newValue;
  }
}
