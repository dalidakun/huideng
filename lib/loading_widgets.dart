import 'package:flutter/material.dart';

import 'app_palette.dart';
/// 统一的金色主题色，与项目其他页面保持一致
Color get kLoadingGold => AppPalette.p.accent;
/// 
/// 用于替代单纯的 CircularProgressIndicator，提升用户体验
class AppLoadingIndicator extends StatelessWidget {
  final String? message;
  final double size;
  final double strokeWidth;
  final Color? color;

  const AppLoadingIndicator({
    super.key,
    this.message,
    this.size = 24,
    this.strokeWidth = 2.2,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? kLoadingGold;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              strokeWidth: strokeWidth,
              color: effectiveColor,
            ),
          ),
          if (message != null && message!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              message!,
              style: textTheme.bodyMedium?.copyWith(
                color: textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 加载失败组件
/// 
/// 提供友好的错误提示和重试按钮
class AppLoadError extends StatelessWidget {
  final String title;
  final String subtitle;
  final String buttonText;
  final VoidCallback? onRetry;
  final IconData icon;

  const AppLoadError({
    super.key,
    this.title = '加载失败',
    this.subtitle = '网络似乎不太顺畅',
    this.buttonText = '点击重试',
    this.onRetry,
    this.icon = Icons.wifi_off_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 52,
              color: textTheme.bodyMedium?.color?.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: kLoadingGold,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
                child: Text(
                  buttonText,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 空状态组件
/// 
/// 用于显示列表为空时的提示
class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? child;

  const AppEmptyState({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.title,
    this.subtitle,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 52,
              color: textTheme.bodyMedium?.color?.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                ),
              ),
            ],
            if (child != null) ...[
              const SizedBox(height: 18),
              child!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 列表底部加载更多指示器
/// 
/// 用于分页加载时显示在列表底部
class AppLoadMoreIndicator extends StatelessWidget {
  final String? message;
  final bool hasError;
  final VoidCallback? onRetry;

  const AppLoadMoreIndicator({
    super.key,
    this.message,
    this.hasError = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    if (hasError) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Center(
          child: GestureDetector(
            onTap: onRetry,
            child: Text(
              message ?? '加载失败，点击重试',
              style: textTheme.bodySmall?.copyWith(
                color: textTheme.bodySmall?.color?.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: kLoadingGold,
              ),
            ),
            if (message != null && message!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                message!,
                style: textTheme.bodySmall?.copyWith(
                  color: textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
