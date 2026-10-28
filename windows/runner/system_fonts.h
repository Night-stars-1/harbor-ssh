#ifndef RUNNER_SYSTEM_FONTS_H_
#define RUNNER_SYSTEM_FONTS_H_

#include <string>
#include <vector>

// Installed font families whose regular face DirectWrite reports as
// monospaced, as UTF-8 names (en-us when available). Empty on failure.
std::vector<std::string> MonospaceFontFamilies();

#endif  // RUNNER_SYSTEM_FONTS_H_
