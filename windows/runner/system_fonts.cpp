#include "system_fonts.h"

#include <dwrite_1.h>
#include <wrl/client.h>

#include "utils.h"

using Microsoft::WRL::ComPtr;

namespace {

std::string FamilyName(IDWriteFontFamily* family) {
  ComPtr<IDWriteLocalizedStrings> names;
  if (FAILED(family->GetFamilyNames(&names))) return {};
  UINT32 index = 0;
  BOOL exists = FALSE;
  // Skia resolves any localized name; en-us keeps the stored value stable
  // across system display languages.
  if (FAILED(names->FindLocaleName(L"en-us", &index, &exists)) || !exists) {
    index = 0;
  }
  UINT32 length = 0;
  if (FAILED(names->GetStringLength(index, &length))) return {};
  std::wstring name(length + 1, L'\0');
  if (FAILED(names->GetString(index, name.data(), length + 1))) return {};
  name.resize(length);
  return Utf8FromUtf16(name.c_str());
}

bool IsMonospaced(IDWriteFontFamily* family) {
  ComPtr<IDWriteFont> font;
  if (FAILED(family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL,
                                          DWRITE_FONT_STRETCH_NORMAL,
                                          DWRITE_FONT_STYLE_NORMAL, &font))) {
    return false;
  }
  ComPtr<IDWriteFontFace> face;
  ComPtr<IDWriteFontFace1> face1;
  return SUCCEEDED(font->CreateFontFace(&face)) &&
         SUCCEEDED(face.As(&face1)) && face1->IsMonospacedFont();
}

}  // namespace

std::vector<std::string> MonospaceFontFamilies() {
  std::vector<std::string> families;
  ComPtr<IDWriteFactory> factory;
  if (FAILED(DWriteCreateFactory(
          DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
          reinterpret_cast<IUnknown**>(factory.GetAddressOf())))) {
    return families;
  }
  ComPtr<IDWriteFontCollection> collection;
  if (FAILED(factory->GetSystemFontCollection(&collection, TRUE))) {
    return families;
  }
  const UINT32 count = collection->GetFontFamilyCount();
  families.reserve(count / 4);
  for (UINT32 i = 0; i < count; ++i) {
    ComPtr<IDWriteFontFamily> family;
    if (FAILED(collection->GetFontFamily(i, &family)) ||
        !IsMonospaced(family.Get())) {
      continue;
    }
    std::string name = FamilyName(family.Get());
    if (!name.empty()) families.push_back(std::move(name));
  }
  return families;
}
