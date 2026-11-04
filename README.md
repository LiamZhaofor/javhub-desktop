# JavHub Desktop

JavHub 的 Windows 原生客户端（Flutter）。

- 片库：海报网格、分类 / 位置 / 字幕筛选、排序、搜索，海报缩略图和片库列表缓存在本地
- 详情：剧照、演员 / 片商 / 标签一键筛选、简介、播放、查找其它版本
- 搜索：影片信息、磁力候选、选择下载到 NAS / 115 网盘、加入想看；未搜索时显示个性化推荐
- 任务、想看清单
- 播放器：mpv（media_kit），115 视频经本地代理直连 CDN（最多 2 个连接、分块预读，拖动不卡），NAS 本地视频直接播放；记住播放位置
- 字幕悬浮球：迅雷在线字幕搜索、本地字幕、Subtitlecat、偏移 / 位置 / 大小 / 颜色，Z 按住加速、X / C 快进快退

下载：Releases 里的 `latest` 预发布版，解压后运行 `JavHub.exe`。

构建：GitHub Actions（`.github/workflows/build.yml`）——Linux 上分析 + 单元测试，然后 Windows 构建并发布。
