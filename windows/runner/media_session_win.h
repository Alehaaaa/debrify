#ifndef RUNNER_MEDIA_SESSION_WIN_H_
#define RUNNER_MEDIA_SESSION_WIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <mutex>
#include <vector>

// The in-app player's entry in Windows' media overlay (System Media Transport
// Controls): title, poster and progress, with the keyboard media keys, the
// volume flyout and Bluetooth headsets driving play/pause/skip/seek. Fed from
// Dart over `debrify/media_session`; commands go back as `command`.
class MediaSessionWin {
 public:
  // Message posted to |window| when a control was pressed; the window's
  // procedure calls FlushCommands() for it on the platform thread.
  static constexpr UINT kCommandMessage = WM_APP + 0x51;

  MediaSessionWin(flutter::BinaryMessenger* messenger, HWND window);
  ~MediaSessionWin();

  void FlushCommands();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_MEDIA_SESSION_WIN_H_
