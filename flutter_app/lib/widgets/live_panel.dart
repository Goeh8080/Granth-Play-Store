import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../services/catalog_store.dart';
import '../state/ui_prefs.dart';

/// Rebuilds a screen when its inputs change.
///
/// The panels are `const` widgets inside the home shell, so a parent rebuild skips them:
/// before this, the 1×1 / 2×2 / 3×3 switch, the सेटिंग layout / card-style choices and a
/// finished sync were saved but never shown until you left the screen. Panels now listen
/// to [UiPrefs] directly, and to the catalog only when its data really changes (not on
/// every image-download tick).
mixin LivePanel<T extends StatefulWidget> on State<T> {
  late final CatalogStore _store = CatalogStore.I;
  late int _version = _store.catalogVersion;
  SyncStatus? _status;

  @override
  void initState() {
    super.initState();
    _status = _store.status;
    UiPrefs.I.addListener(_refresh);
    _store.addListener(_onStore);
  }

  @override
  void dispose() {
    UiPrefs.I.removeListener(_refresh);
    _store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (_store.catalogVersion == _version && _store.status == _status) return;
    _version = _store.catalogVersion;
    _status = _store.status;
    _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }
}
