import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/chat_models.dart';

class ChatServiceCard extends StatelessWidget {
  const ChatServiceCard({super.key, required this.reference, this.foreground});

  final ChatServiceReference reference;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final color = foreground ?? Theme.of(context).colorScheme.onSurface;
    return Material(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            context.push('/service/${Uri.encodeComponent(reference.id)}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.storefront_outlined, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'About this service',
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      reference.title,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
