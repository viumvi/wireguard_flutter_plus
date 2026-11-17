import 'package:flutter/material.dart';

class TrafficStatsWidget extends StatelessWidget {
  final String downloadSpeed;
  final String uploadSpeed;
  final String totalDownload;
  final String totalUpload;
  final String duration;

  const TrafficStatsWidget({
    super.key,
    required this.downloadSpeed,
    required this.uploadSpeed,
    required this.totalDownload,
    required this.totalUpload,
    this.duration = "00:00:00",
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                context,
                "Download",
                downloadSpeed,
                totalDownload,
                Icons.arrow_downward,
                Colors.greenAccent,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildStatCard(
                context,
                "Upload",
                uploadSpeed,
                totalUpload,
                Icons.arrow_upward,
                Colors.blueAccent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildDurationCard(
          context,
          "Connection Time",
          duration,
          Icons.timer_outlined,
          Colors.amberAccent,
        ),
      ],
    );
  }

  Widget _buildDurationCard(
    BuildContext context,
    String title,
    String durationValue,
    IconData icon,
    Color color,
  ) {
    return Card(
      elevation: 0,
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 22, color: color),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF94A3B8),
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  durationValue,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        letterSpacing: 1.2,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(
    BuildContext context,
    String title,
    String speed,
    String total,
    IconData icon,
    Color color,
  ) {
    return Card(
      elevation: 0, // Flat card style
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF94A3B8),
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              speed,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              "Total: $total",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF64748B),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
