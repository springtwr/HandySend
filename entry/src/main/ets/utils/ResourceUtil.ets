import { common } from '@kit.AbilityKit';

// 资源字符串同步获取的唯一实现：null 安全（无上下文返回 ''）。
// 收敛各 View/Page/VM 中重复的 getHostContext + getStringSync 样板。
export function getStringSync(uiContext: UIContext, res: Resource): string {
  let ctx = uiContext.getHostContext();
  if (ctx === undefined) {
    return '';
  }
  try {
    return ctx.resourceManager.getStringSync(res.id);
  } catch (_e) {
    return '';
  }
}

// UIAbilityContext 直接版本（VM 持有 AbilityContext 而非 UIContext 时使用）。
export function getStringSyncFromContext(context: common.UIAbilityContext | undefined, res: Resource): string {
  if (context === undefined) {
    return '';
  }
  try {
    return context.resourceManager.getStringSync(res.id);
  } catch (_e) {
    return '';
  }
}
