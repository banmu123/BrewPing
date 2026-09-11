/// 会话内容主列 —— 布局系统的宪法（规格 §3，逐字对齐 Lody conversation-layout.ts）。
/// 三条铁律：
/// 1. 每个全幅区域（表头 / 消息行 / composer）各挂一个列组件，页面级不套父容器——
///    滚动容器保持全宽，内容各自进列；
/// 2. 水平留白必须挂在列上，不能挂在滚动容器上（虚拟化行会无视容器 padding）；
/// 3. 禁止在列实例上加 `ml-*`（会覆盖 mx-auto，把行钉死在面板边缘）。

/** 水平内缩：表头、消息行、上下文条、composer 共享 */
export const CONVERSATION_GUTTER_X_CLASS = "px-3 sm:px-4";

/** 46rem = 736px：max-w-3xl(48rem) 减 1rem 侧距——够放代码块，又不失可读性 */
export const CONVERSATION_CONTENT_WIDTH_CLASS = `mx-auto w-full max-w-[46rem] ${CONVERSATION_GUTTER_X_CLASS}`;
