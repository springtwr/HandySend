// 设备类型图标映射：将 deviceType 字符串映射到 SVG 图标资源。
// 使用 Image 组件渲染，通过 fillColor 着色。

import { resolveMtaPhoneBrandIcon } from '../model/mta/MtaBrandRegistry';

export function getDeviceIconResource(deviceType: string): Resource {
  if (deviceType === 'desktop') {
    return $r('app.media.ic_device_desktop');
  } else if (deviceType === 'web') {
    return $r('app.media.ic_device_web');
  } else if (deviceType === 'headless') {
    return $r('app.media.ic_device_headless');
  } else if (deviceType === 'server') {
    return $r('app.media.ic_device_server');
  } else if (deviceType === 'tablet') {
    return $r('app.media.ic_device_tablet');
  }
  return $r('app.media.ic_device_mobile');
}

/**
 * 对端设备图标（详情页设备卡与发送页设备列表同源规则）：
 * mtaBrandId 非 undefined 即 MTA 来源 → 返回品牌彩色图标（-1 为未知品牌，回退默认 MTA 图标）；
 * 否则按 deviceType 返回设备类型图标（缺失/未知回退手机图标）。
 */
export function getPeerDeviceIconResource(deviceType: string, mtaBrandId: number | undefined): Resource {
  if (mtaBrandId !== undefined) {
    return resolveMtaPhoneBrandIcon(mtaBrandId);
  }
  return getDeviceIconResource(deviceType);
}
