# 书架与朗读体验回归

Debug 模拟器包支持 `--library-regression`。验证使用 App 缓存目录内独立的
`BookshelfLibraryRegression`，不访问正式书架；输出为 App Documents 下的
`library-results.txt`。

覆盖内容：

- 旧版 Book / ReaderLocator JSON 缺少新增字段时仍能解码。
- 按“正常 TXT、损坏 EPUB、正常 TXT”顺序导入，成功两本，单本失败不影响后续。
- 失败导入不留下书籍文件，导入状态正常复位。
- 收藏、已读完、书名作者、格式、最近阅读时间重启后保留。
- 精确百分比、连续更新合并写入与退出前刷新。
- 搜索空格处理、阅读状态筛选、最近阅读和进度排序。
- 睡眠定时的截止时间、到期停止、取消与关闭阅读页后的清理。
- 真实旧版数组索引迁移到带版本索引，缺省书单与删除状态兼容。
- 书单名称校验、多书单归属、重命名与重启保留；删除书单不删除书籍。
- Markdown 转义、中文多行划线与笔记的纯文本保留，排除遗留书签。
- 最近删除保留书籍文件、笔记、书单、最新进度与历史，重复删除不重复记录。
- 永久删除仅适用于最近删除；模拟提交前 / 后中断并重启恢复。
- 模拟索引写入失败，书籍文件回滚；损坏索引不会被覆盖。

所有删除、损坏文件和中断模拟均在专用缓存夹中进行，不触碰正式书架。

运行示例（替换模拟器 ID）：

```sh
xcodebuild -project BookShelf.xcodeproj -scheme BookShelf -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bookshelf-qa \
  build CODE_SIGNING_ALLOWED=NO
xcrun simctl install DEVICE_ID /tmp/bookshelf-qa/Build/Products/Debug-iphonesimulator/BookShelf.app
xcrun simctl launch DEVICE_ID com.Voltline.BookShelf --library-regression
```

成功后界面展示隔离书架。附加 `-library.layout grid` 可预览网格；附加
`--preview-details` 或 `--preview-import` 可预览详情、混合成功失败的导入结果。
第二轮新增 `--preview-collections`、`--preview-membership`、`--preview-deleted`、
`--preview-export`，分别检查书单管理、加入书单、最近删除和标注导出。

手动检查：

1. 列表 / 网格切换、书籍“…”菜单、收藏和已读完状态同步。
2. 筛选无结果时能恢复全部，搜索与筛选可以组合。
3. 修改书名作者后打开书籍，返回书架保留信息与阅读进度。
4. 阅读设置中选择定时，关闭再打开仍显示剩余时间；取消后消失。
5. 连续翻页后切后台、重新打开，位置与书架百分比一致。
6. 新建两个书单，把同一本书加入两个书单；分别筛选，确认都可见。取消加入不删除书籍。
7. 删除书单，确认书籍仍在全部书籍中；重命名当前书单，标题同步更新。
8. 划线面板和书籍详情导出单本笔记，书架菜单导出全部；用“文件”存储 Markdown / TXT 并打开，确认扩展名和中文内容正确。
9. 删除书籍后在“最近删除”恢复，确认位置、书单、划线笔记未丢失；永久删除和清空都必须二次确认。
10. 导出预览和存储 / 分享取消不改变阅读进度，取消加入书单不提交选择。
