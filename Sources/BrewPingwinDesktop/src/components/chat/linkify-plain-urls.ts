/// 裸 URL 自动链接（渲染栈规格 §3.1 remarkLinkifyPlainUrls 的最小复刻）。
/// 匹配 https?:// 与 www.（后者补 https://）。
///
/// ★ 中文标点边界处理（规格原文要点）：中文书写无空格，
///   `见 https://example.com/a。然后` 会把整句吞进链接。
///   解法：非 ASCII 标点/分隔符（，。、；：？！「」（）全角空格…）终止 URL；
///   非 ASCII 字母仍可出现在 URL 内（如 /wiki/中文）。
const URL_PATTERN = /https?:\/\/[^\s<>"]+|www\.[^\s<>"]+/gi;

/// 非 ASCII 标点/分隔符 → URL 终止符（规格 NON_ASCII_URL_BOUNDARY 等价实现）
const NON_ASCII_URL_BOUNDARY = /(?!\p{ASCII})[\p{P}\p{Z}]/u;

/// URL 末尾的闭合符剥离：) ] } " ' . , : ; ! ? —— 括号配平才剥，否则视为 URL 一部分
function splitAutolinkTrailing(raw: string): { url: string; trailing: string } {
  let url = raw;
  let trailing = "";
  const closers = ")]}\"'.,;:!?";
  while (url.length > 0) {
    const last = url[url.length - 1];
    if (!closers.includes(last)) break;
    if (last === ")") {
      const opens = (url.match(/\(/g) ?? []).length;
      const closes = (url.match(/\)/g) ?? []).length;
      // 括号不配平 → 这个 ) 属于 URL（维基百科式），保留
      if (closes > opens) break;
    }
    trailing = last + trailing;
    url = url.slice(0, -1);
  }
  return { url, trailing };
}

/// 中文标点截断 + 尾部闭合修正
function extractUrl(raw: string): { url: string; trailing: string } | null {
  let text = raw;
  let trailing = "";
  // 中文标点截断：找到第一个非 ASCII 标点/分隔符，其后是尾随文本
  for (let i = 0; i < text.length; i++) {
    if (NON_ASCII_URL_BOUNDARY.test(text[i])) {
      trailing = text.slice(i) + trailing;
      text = text.slice(0, i);
      break;
    }
  }
  if (/^www\./i.test(text)) text = "https://" + text;
  if (text.length < 5) return null; // "http:" 都不够，防御
  const split = splitAutolinkTrailing(text);
  return { url: split.url, trailing: split.trailing + trailing };
}

interface MdNode {
  type: string;
  value?: string;
  url?: string;
  title?: string | null;
  children?: MdNode[];
}

/// 遍历 mdast，原位把 text 节点中的裸 URL 替换为 link 节点。
/// 跳过 link / code / inlineCode 内部（与规格一致，防止二次改写）。
function walk(node: MdNode) {
  if (!node.children) return;
  const newChildren: MdNode[] = [];
  let changed = false;
  for (const child of node.children) {
    if (child.type === "text" && child.value && URL_PATTERN.test(child.value)) {
      URL_PATTERN.lastIndex = 0; // matchAll 外的单测用；test 会推进 lastIndex
      changed = true;
      newChildren.push(...linkifyText(child.value));
    } else {
      if (child.type !== "link" && child.type !== "code" && child.type !== "inlineCode") {
        walk(child);
      }
      newChildren.push(child);
    }
  }
  if (changed) node.children = newChildren;
}

function linkifyText(value: string): MdNode[] {
  const out: MdNode[] = [];
  let last = 0;
  for (const match of value.matchAll(URL_PATTERN)) {
    const idx = match.index ?? 0;
    if (idx > last) out.push({ type: "text", value: value.slice(last, idx) });
    const parsed = extractUrl(match[0]);
    if (parsed) {
      out.push({
        type: "link",
        url: parsed.url,
        title: null,
        children: [{ type: "text", value: parsed.url }],
      });
      if (parsed.trailing) out.push({ type: "text", value: parsed.trailing });
    } else {
      out.push({ type: "text", value: match[0] });
    }
    last = idx + match[0].length;
  }
  if (last < value.length) out.push({ type: "text", value: value.slice(last) });
  return out;
}

/// remark 插件入口。模块级单例（渲染栈规格红线：不得在渲染函数里新建插件）。
export function remarkLinkifyPlainUrls() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (tree: any) => {
    walk(tree as unknown as MdNode);
  };
}
