import 'package:flutter/widgets.dart';

import 'ui_prefs.dart';

/// Whether the decorative entrance animations (scale-pop, blur-focus, inner stagger,
/// app-open fade) may play: the setting "एनिमेशन" is चालू AND the phone's own
/// "remove animations" (accessibility) is not on. Existing functional animations (count-up,
/// menu, tilt, splash) don't ask: they are unchanged.
class Motion {
  Motion._();
  static bool on(BuildContext context) => UiPrefs.I.animations && !MediaQuery.disableAnimationsOf(context);
}
