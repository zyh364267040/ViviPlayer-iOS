# 菜单 UI 测试

`DrivePlayerMusicMenuUI` scheme 有 13 项测试：普通字号 12 项、最大辅助字号 1 项，分开运行。一次正常批次失败不能算作整套通过。

仅用专门创建的 iPhone 模拟器和合成媒体，绝不使用个人媒体或真机。`tools/generate-ui-wavs.py` 生成两首 10 分钟、不同标题的 WAV 和同名小写 `.lrc`。公开示例 App ID 为 `com.example.DrivePlayer`；如自行更改 App ID，须同时调整测试源码中的 App ID。

在仓库根目录执行（先将 `SIM_ID` 设为你自己的独立模拟器 UUID）：

```sh
export SIM_ID='<your-isolated-simulator-uuid>'
python3 tools/generate-ui-wavs.py .build/ui-fixtures || exit 1
xcrun simctl bootstatus "$SIM_ID" -b || exit 1
xcodebuild build -project DrivePlayer.xcodeproj -scheme DrivePlayer \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$PWD/.build/UITestDerived" CODE_SIGNING_ALLOWED=NO || exit 1
xcrun simctl install "$SIM_ID" \
  "$PWD/.build/UITestDerived/Build/Products/Debug-iphonesimulator/DrivePlayer.app" || exit 1
container=$(xcrun simctl get_app_container "$SIM_ID" com.example.DrivePlayer data) || exit 1
mkdir -p "$container/Documents"
# Only use a new, empty simulator App container; do not overwrite any media.
python3 -c 'from pathlib import Path; import shutil,sys; src=Path(sys.argv[1]); dst=Path(sys.argv[2]); files=list(src.iterdir()); len(list(dst.iterdir())) == 0 or sys.exit("Documents is not empty; stop rather than touching existing media"); [shutil.copy2(f,dst/f.name) for f in files]' \
  "$PWD/.build/ui-fixtures" "$container/Documents" || exit 1
export TEST_RUNNER_VIVI_SYNTHETIC_TRACK_TITLE='UIA-Synthetic-00'
export TEST_RUNNER_VIVI_SYNTHETIC_LYRICS_TRACK_TITLE='UIL-Synthetic-01'
original_size=$(xcrun simctl ui "$SIM_ID" content_size) || exit 1
restore_size() {
  xcrun simctl ui "$SIM_ID" content_size "$original_size"
  xcrun simctl ui "$SIM_ID" content_size
}
trap restore_size EXIT

xcrun simctl ui "$SIM_ID" content_size large || exit 1
[ "$(xcrun simctl ui "$SIM_ID" content_size)" = large ] || exit 1
unset TEST_RUNNER_VIVI_SYSTEM_CONTENT_SIZE
xcodebuild test -project DrivePlayer.xcodeproj -scheme DrivePlayerMusicMenuUI \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$PWD/.build/UITestDerived" CODE_SIGNING_ALLOWED=NO \
  -skip-testing:DrivePlayerUITests/MusicMenuUITests/testLargeTextCompletionOptionsReachableAndSelected
normal_exit=$?

xcrun simctl ui "$SIM_ID" content_size accessibility-extra-extra-extra-large || exit 1
[ "$(xcrun simctl ui "$SIM_ID" content_size)" = accessibility-extra-extra-extra-large ] || exit 1
export TEST_RUNNER_VIVI_SYSTEM_CONTENT_SIZE=accessibility-extra-extra-extra-large
# The test process reads VIVI_SYSTEM_CONTENT_SIZE after Xcode removes TEST_RUNNER_.
xcodebuild test -project DrivePlayer.xcodeproj -scheme DrivePlayerMusicMenuUI \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath "$PWD/.build/UITestDerived" CODE_SIGNING_ALLOWED=NO \
  -only-testing:DrivePlayerUITests/MusicMenuUITests/testLargeTextCompletionOptionsReachableAndSelected
large_exit=$?
unset TEST_RUNNER_VIVI_SYSTEM_CONTENT_SIZE
printf 'normal (12): exit %s; large (1): exit %s\n' "$normal_exit" "$large_exit"
[ "$normal_exit" -eq 0 ] && [ "$large_exit" -eq 0 ] || exit 1
```

字号确认变量不能替代实际系统设置及读回；退出时由 trap 恢复原字号。截图、AX 树和测试结果包分享前须检查；模拟器测试不替代真机触摸、听感、后台锁屏或车载蓝牙验收。
