const config = require('./utils/config');

App({
  globalData: {
    config,
  },
  onLaunch() {
    // 首版纯本地，不初始化云开发；后续填 config.cloudEnv 后启用。
    if (config.cloudEnv && wx.cloud) {
      try {
        wx.cloud.init({ env: config.cloudEnv, traceUser: false });
      } catch (e) {}
    }
  },
});
