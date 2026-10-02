import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// The app's current interface is Simplified Chinese. Built-in widgets must
// resolve the same locale even when the operating system uses another language.
const harborLocale = Locale('zh', 'CN');
const harborSupportedLocales = [harborLocale];
const harborLocalizationDelegates = <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];
