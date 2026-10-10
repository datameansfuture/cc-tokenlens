# Token Lens

[English](README.md) | [简体中文](README.zh-CN.md)

一个给 [Claude Code](https://claude.com/claude-code) 用的两行状态栏,显示一个
会话在 token 上实际花了多少 —— 一个持续攀升的数字,而不是每次对话被压缩就归零
的那个。

```
7.5M │ deepseek-flash 6.9M↓ 765k↑
~/projects/my-app ████████░░░░ 43%
```

## 为什么不用自带的那个数字

Claude Code 给状态栏一个 `context_window` 块,里面有 `total_input_tokens` 和
`total_output_tokens`。它们看着像会话累计值,其实不是。它们是**当前上下文窗口的
快照**:

- 一个 636 条记录的会话上,`total_output_tokens` 读出是 `75`。而该会话这些记录
  实际产出是 530k。
- `total_input_tokens` 在相隔几秒的两次渲染之间,从 `193371` 变到 `113566`。
- 自动压缩触发时窗口重建,两个字段一起归零,状态栏显示 `0↓ 0↑`,直到下一轮再填上。

整个 payload 里没有任何累计 token 字段。`cost.total_cost_usd` 是全会话范围的,
但钱不等于 token。所以这里改为对会话 transcript 求和 —— 它只增不减,且不受压缩
影响。

## 统计什么

对 transcript 里每条 assistant 记录:

```
down += input_tokens + cache_creation_input_tokens
up   += output_tokens
```

`cache_read_input_tokens` 是**故意排除**的。在一个长会话上,它是输入侧原始总量
84.7M 里的 79.3M —— 92.7% —— 因为每一轮都会重发整个已缓存的上下文。把它算进去
这个数字就没意义了。算的是真正新增的输入加输出:会话消耗掉的,而非重复读到的。

想换算法就改 `cc-statusline-tokens.py`;对应常量是 `CACHE_VERSION`,改了数据结构
的形状之后它会强制丢弃旧缓存。

### 增量

transcript 只增不减、每轮变大,所以每次状态栏刷新都重新解析一遍是浪费。
`cc-statusline-tokens.py` 按 transcript 缓存累计值和已消费的字节偏移,每次调用
只解析之后追加的那部分。全程以字节为单位,所以消息内容里的多字节 UTF-8 不会
让偏移错位;且只消费完整行 —— 写到一半的文件下一次调用补完。transcript 比记录的
偏移还短(被截断或替换)则重新扫描。

开销约为:5MB transcript 热态 28ms,冷态全扫 68ms。

## 显示什么

第一行由三部分拼成:

- **caveman 的省量数字** —— 你的配置省下的 token 数。从 `caveman` plugin 的状态栏
  里读出来,只取数字。
- **模型标签** —— 来自
  [`@alyibrahim/claude-statusline`](https://github.com/AlyIbrahim1/claude-statusline)。
- **本会话 token** —— 本项目自己的贡献。

第二行是目录和上下文进度条,同样来自 claude-statusline。

## 安装

`cc-statusline.sh` 会相对自身解析那两个辅助文件,所以两个文件放在 clone 下来
的目录里并排放着即可。让 Claude Code 指过去:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/tokenlens_for_claudecode/cc-statusline.sh"
  }
}
```

`/plugin` 和 `settings.json` 都行;放在哪个由你的环境长期持有决定 —— 有些切换
订阅的工具每次切换都会重写 `settings.json`。

### 依赖

- **可选。** `caveman` —— 提供省量数字。没有它那一行会少这一段。
- **可选。** `@alyibrahim/claude-statusline` —— 提供模型标签和上下文进度条。通过
  `npm root -g` 定位,所以任何 npm prefix 都行;没有它这行会退化成只剩 token,
  而不是崩掉。
- **必需。** `python3`,用于 token 计数。没有它状态栏什么都不渲染。

两个可选依赖都不内置也不强制。脚本降级时是变少,而不是报错 —— 因为退出码非零的
状态栏会被 Claude Code 直接隐藏,坏掉的比朴素的更糟。

## 一些说明

- claude-statusline 是**故意**用 `COLUMNS=200` 调用的。它的 `wrapChunks()` 在
  真实终端窄的时候会把目录挤到第二行,而这个脚本做的 `│` 切分届时会把模型名
  捕获两次 —— 每行各一次。
- stdin 带一秒上限读取。裸 `cat` 在写入方不关管道时会永远阻塞,那会把状态栏
  线程整个会话都钉住。
- macOS 出厂 bash 3.2,拒绝小数的 `read -t` 超时。

## 许可

MIT。
