// 设备类型图标映射：将 deviceType 字符串映射到 SVG 图标资源。
// 使用 Image 组件渲染，通过 fillColor 着色。

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
