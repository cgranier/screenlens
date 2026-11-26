import QtQuick

// Every dynamic display string in ScreenLens renders through PlainText so
// untrusted OCR output, window titles, or AI responses can never be parsed
// as Qt rich text or trigger external resource loads.
Text {
  textFormat: Text.PlainText
}
