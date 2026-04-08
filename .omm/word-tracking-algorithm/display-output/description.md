显示输出层。将匹配算法输出的 currentWord 索引渲染为可视化的提词器界面：
- 当前词高亮（primary color），已读词淡化（opacity 0.3），未读词渐变淡化
- 自动滚动：将当前词定位到屏幕 1/3 高度的参考线位置
- 使用 GlobalKey 定位每个词的渲染位置，animateTo 平滑滚动
- Wrap 布局实现自然换行，支持镜像模式（Transform 水平翻转）
