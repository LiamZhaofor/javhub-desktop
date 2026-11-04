import 'package:flutter/material.dart';

import '../app.dart';
import '../player/settings.dart';

const appVersion = '0.1.0';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Text('设置', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('服务器'),
              subtitle: Text('${App.api.server}  ·  ${App.api.user}${App.api.lan ? '  ·  局域网' : ''}'),
              trailing: OutlinedButton(
                onPressed: () async {
                  await App.api.logout();
                  onLogout();
                },
                child: const Text('退出登录'),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('115 播放'),
              subtitle: Text('本机直连 115 CDN，经内置本地代理（最多 2 个连接、2 MB 分块预读），不占家里上行；拖动后从新位置继续。',
                  style: TextStyle(color: hint)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: const Text('字幕与快捷键'),
              subtitle: Text('播放时点画面上的「字幕」球调整：在线字幕搜索、偏移、位置、大小、颜色，按住加速键加速，快进 / 快退键。',
                  style: TextStyle(color: hint)),
              trailing: TextButton(
                onPressed: () async {
                  await JavPlayerSettings().save();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已恢复默认的字幕和快捷键设置')));
                  }
                },
                child: const Text('恢复默认'),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.keyboard_outlined),
            title: const Text('播放器快捷键'),
            subtitle: Text(
              '空格 播放/暂停 · ←/→ 后退/前进 10 秒 · ↑/↓ 音量 · F / 双击 全屏 · Esc 退出全屏/返回\n'
              'Z 按住 3 倍速 · X / C 快进 / 快退 5 秒（可在字幕球里改）',
              style: TextStyle(color: hint, height: 1.6),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('JavHub Desktop $appVersion', style: TextStyle(color: hint, fontSize: 12)),
      ],
    );
  }
}
