import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "../../lib/utils";

/// shadcn/ui Badge。success / warning 按规范 §6.6：
/// 语义色 12% 淡底 + 20% 描边 + 语义色文字。
const badgeVariants = cva(
  "inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-semibold transition-colors cursor-default",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-foreground shadow-xs",
        secondary: "bg-secondary text-secondary-foreground",
        destructive: "bg-destructive/12 text-destructive border border-destructive/20",
        outline: "border border-border text-foreground",
        success: "bg-success/12 text-success border border-success/20",
        warning: "bg-warning/12 text-warning border border-warning/20",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

function Badge({ className, variant, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ variant }), className)} {...props} />;
}

export { Badge, badgeVariants };
