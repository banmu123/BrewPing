import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

/// shadcn/ui 标配合成类名工具：clsx 条件合并 + tailwind-merge 去冲突。
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
