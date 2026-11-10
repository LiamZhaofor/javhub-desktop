import 'package:flutter/material.dart';

import '../models.dart';

/// 下载到: where a download goes and, for a 115 one, into which of its library folders.
class DestPicker extends StatelessWidget {
  const DestPicker({super.key, required this.backends, required this.dest, required this.folder, required this.onChanged, this.disabled = const {}});

  final Backends? backends;
  final String dest;

  /// '' = the destination's usual folder.
  final String folder;
  final void Function(String dest, String folder) onChanged;

  /// Destinations that cannot take this download (shown, not selectable).
  final Set<String> disabled;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final ok = backends?.items.where((b) => b.ok).toList() ?? [];
    final off = backends?.items.where((b) => !b.ok && b.name != 'qbittorrent').map((b) => b.title).toSet() ?? {};
    final chosen = ok.where((x) => x.name == dest).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('下载到', style: TextStyle(color: hint)),
        const SizedBox(height: 6),
        if (ok.isEmpty)
          Text('没有可用的下载方式，请在网页端「状态」页检查', style: TextStyle(color: Theme.of(context).colorScheme.error))
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final b in ok)
                ChoiceChip(
                  selected: dest == b.name,
                  onSelected: disabled.contains(b.name) ? null : (_) => onChanged(b.name, ''),
                  label: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(b.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(b.subtitle, style: TextStyle(fontSize: 11, color: hint)),
                    ],
                  ),
                ),
            ],
          ),
        if (chosen != null && chosen.dir.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(children: [
              Icon(Icons.folder_open_rounded, size: 18, color: hint),
              const SizedBox(width: 6),
              Text('保存到  ', style: TextStyle(color: hint)),
              Flexible(
                child: chosen.dirs.length > 1
                    ? DropdownButton<String>(
                        value: folder.isEmpty ? chosen.dir : folder,
                        isDense: true,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        borderRadius: BorderRadius.circular(10),
                        items: [for (final d in chosen.dirs) DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis))],
                        onChanged: (v) => onChanged(dest, v == chosen.dir ? '' : (v ?? '')),
                      )
                    : Text(chosen.dir, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        if (off.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${off.join('、')} 需先在网页端「网盘」页登录后才能选', style: TextStyle(color: hint, fontSize: 12)),
          ),
      ],
    );
  }
}
