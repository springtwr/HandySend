// commitlint 配置 — 匹配 COMMIT_CONVENTION.md 规范
// 安装：npm install -g @commitlint/cli @commitlint/config-conventional

export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // type 必须使用 COMMIT_CONVENTION.md 中定义的类型
    'type-enum': [
      2,
      'always',
      [
        'feat',
        'fix',
        'docs',
        'style',
        'refactor',
        'perf',
        'test',
        'build',
        'ci',
        'chore',
        'revert',
      ],
    ],
    // scope 推荐使用项目定义的范围（不强制，因为文档说"不是封闭列表"）
    'scope-enum': [
      1,
      'always',
      [
        'transfer',
        'discovery',
        'settings',
        'native',
        'bridge',
        'ui',
        'log',
        'build',
      ],
    ],
    // 标题不超过 50 个字符（COMMIT_CONVENTION.md 要求）
    'subject-max-length': [2, 'always', 50],
    // 标题不以句号结尾
    'subject-full-stop': [2, 'never', '.。'],
    // 标题不为空
    'subject-empty': [2, 'never'],
    // type 不为空
    'type-empty': [2, 'never'],
    // scope 为空时不加括号
    'scope-case': [2, 'always', 'lower-case'],
    // type 小写
    'type-case': [2, 'always', 'lower-case'],
    // 正文每行不超过 72 个字符
    'body-max-line-length': [2, 'always', 72],
    // footer 每行不超过 72 个字符
    'footer-max-line-length': [2, 'always', 72],
  },
};
