enum TransferDirection { sending, receiving }

enum TransferState { queued, active, complete, failed, cancelled }

class TransferTask {
  TransferTask({
    required this.id,
    required this.name,
    required this.totalBytes,
    required this.direction,
  }) : startedAt = DateTime.now();

  final String id;
  final String name;
  final int totalBytes;
  final TransferDirection direction;
  final DateTime startedAt;
  int transferredBytes = 0;
  double bytesPerSecond = 0;
  TransferState state = TransferState.queued;
  String? error;

  double get progress => totalBytes == 0
      ? (state == TransferState.complete ? 1 : 0)
      : (transferredBytes / totalBytes).clamp(0, 1);
}
