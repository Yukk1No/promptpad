匹配编排器，即 ScriptMatcher.match() 方法。协调四种匹配策略的执行顺序：
1. 字符级匹配 + 词级匹配并行执行，取最大值
2. 尾部重锚定在主匹配之后运行，用于修正漂移
3. 重同步仅在连续 3 次无进展且收到 final 结果时触发

状态管理：维护 _matchStartOffset（搜索起点）和 _recognizedCharCount（已确认位置），final 结果时推进起点。
