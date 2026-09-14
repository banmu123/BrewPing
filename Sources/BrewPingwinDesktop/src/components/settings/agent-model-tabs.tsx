import { Globe } from "lucide-react";
import { cn } from "../../lib/utils";

export interface AgentTabItem {
  /** tab 对应的厂商归属（"" = 通用，所有 Agent 可用）。 */
  id: string;
  name: string;
}

/**
 * Agent 归属 Tab 栏（P2）：
 * 「通用」+ 每个已发现 Agent 一个 tab；横向滚动消化溢出。
 * tab 只切过滤视图（专属 + 通用带徽章），不改数据 —— 数据层约定见
 * model_provider_store.rs（agent_id 归属 + current_by_agent 分槽）。
 */
export function AgentModelTabs({
  tabs,
  activeId,
  onSelect,
}: {
  tabs: AgentTabItem[];
  activeId: string;
  onSelect: (id: string) => void;
}) {
  return (
    <div className="mb-2 flex items-center gap-1 overflow-x-auto pb-0.5">
      {tabs.map((tab) => {
        const active = tab.id === activeId;
        return (
          <button
            key={tab.id || "__general__"}
            type="button"
            className={cn(
              "flex h-7 shrink-0 items-center gap-1 rounded-md px-2.5 text-[11px] transition-colors",
              active
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-accent hover:text-foreground",
            )}
            onClick={() => onSelect(tab.id)}
          >
            {tab.id === "" && <Globe size={11} className="shrink-0" />}
            <span className="max-w-[140px] truncate">{tab.name}</span>
          </button>
        );
      })}
    </div>
  );
}
