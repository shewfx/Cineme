import 'package:flutter_riverpod/flutter_riverpod.dart';

class InventoryRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Bumped after a Today action changes watchlist, viewings or blocks (Mark
/// watched, Already seen, Never recommend). Watchlist, watched history and
/// Profile watch it and reload, so features need not import each other.
final inventoryRevisionProvider = NotifierProvider<InventoryRevision, int>(
  InventoryRevision.new,
);
