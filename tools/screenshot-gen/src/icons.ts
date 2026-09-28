/**
 * 特性图线性图标集：键为图标名（config.json 的 features.<id>.icon 引用），
 * 值为内联 SVG 字符串——48×48 viewBox、currentColor 描边、圆角端点，
 * 显示尺寸与颜色由模板样式控制（.feature-icon svg）。
 */
export const ICONS: Record<string, string> = {
  // 设备互联：链条环节
  link: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M20 26a10 10 0 0 0 15.08 1.08l6-6a10 10 0 0 0-14.14-14.14l-3.44 3.42"/>
    <path d="M28 22a10 10 0 0 0-15.08-1.08l-6 6a10 10 0 0 0 14.14 14.14l3.42-3.42"/>
  </svg>`,
  // 互传联盟：两台设备之间双向箭头
  mta: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <rect x="3" y="9" width="15" height="30" rx="3.5"/>
    <rect x="30" y="9" width="15" height="30" rx="3.5"/>
    <path d="M21.5 18H26.5M26.5 18l-3-3M26.5 18l-3 3"/>
    <path d="M26.5 30H21.5M21.5 30l3-3M21.5 30l3 3"/>
  </svg>`,
  // 网页版：二维码角标与扫描点
  qr: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <rect x="4" y="4" width="14" height="14" rx="2.5"/>
    <rect x="30" y="4" width="14" height="14" rx="2.5"/>
    <rect x="4" y="30" width="14" height="14" rx="2.5"/>
    <path d="M30 44V32h13"/>
    <rect x="23" y="23" width="5.5" height="5.5" fill="currentColor" stroke="none"/>
    <path d="M39 39h.01" stroke-width="4.5"/>
    <path d="M44 34h.01M34 44h.01" stroke-width="4.5"/>
  </svg>`,
  // 系统集成：经典分享节点图
  share: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <circle cx="24" cy="11.5" r="5.5"/>
    <circle cx="11" cy="33" r="5.5"/>
    <circle cx="37" cy="33" r="5.5"/>
    <path d="M21.2 16.2 13.8 28.3"/>
    <path d="M26.8 16.2 34.2 28.3"/>
  </svg>`,
  // 极速传输：闪电
  bolt: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M27 4 12 27h9.5L18 44l18-24h-9.8L27 4z"/>
  </svg>`,
  // 任务中心：列表条目与状态记号（首行实心圆点表示已完成）
  tasks: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <circle cx="10.5" cy="12" r="4" fill="currentColor" stroke="none"/>
    <path d="M20 12h20"/>
    <circle cx="10.5" cy="24" r="4"/>
    <path d="M20 24h20"/>
    <circle cx="10.5" cy="36" r="4"/>
    <path d="M20 36h14"/>
  </svg>`,
  // 后台传输：通知铃铛内上行传输箭头
  background: `<svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M12 16a12 12 0 0 1 24 0c0 14 6 18 6 18H6s6-4 6-18"/>
    <path d="M20.6 42a3.9 3.9 0 0 0 6.8 0"/>
    <path d="M24 29V19"/>
    <path d="M19.5 23.5 24 19l4.5 4.5"/>
  </svg>`,
};
