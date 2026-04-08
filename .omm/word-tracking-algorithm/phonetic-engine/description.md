简化版 Double Metaphone 语音编码引擎。将英文单词映射为辅音骨架编码，使同音词（right/write/rite）产生相同编码。规则包括：
- 元音：仅在词首编码为 'A'，其余位置忽略
- 辅音合并：B→P, D→T, V→F, Z→S 等
- 双字母处理：CH→X, SH→X, TH→0, PH→F
- 静音前缀跳过：GN, KN, PN, AE, WR
- 软音处理：C 在 E/I/Y 前→S，G 在 E/I/Y 前→J
- 编码截断为最多 4 个字符
- 脚本加载时预计算并缓存所有源词的 Metaphone 编码
