pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    property real elapsed: 0
    readonly property real wordProgress: easeOutCubic(clamp((elapsed - 0.15) / 0.7))
    readonly property real watermarkProgress: easeOutCubic(clamp((elapsed - 0.2) / 1.4))
    readonly property real subtitleProgress: easeOutCubic(clamp((elapsed - 0.45) / 0.7))
    readonly property real fadeProgress: easeInCubic(clamp((elapsed - 2.4) / 0.7))
    readonly property real overlayOpacity: 1 - fadeProgress
    readonly property int settleDelayMs: {
        const configured = Number(Quickshell.env("NIXBOX_SPLASH_SETTLE_MS"));
        return Number.isFinite(configured) && configured >= 0 ? configured : 250;
    }
    property double startedAt: 0

    function beginAnimation() {
        if (startedAt === 0)
            startedAt = Date.now();
    }

    function clamp(value) {
        return Math.max(0, Math.min(1, value));
    }

    function easeOutCubic(value) {
        return 1 - Math.pow(1 - value, 3);
    }

    function easeInCubic(value) {
        return value * value * value;
    }

    Timer {
        interval: 16
        running: root.startedAt > 0
        repeat: true
        onTriggered: {
            root.elapsed = (Date.now() - root.startedAt) / 1000;
            if (root.elapsed >= 3.15)
                Qt.quit();
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: splashWindow

            required property var modelData
            readonly property real layoutScale: Math.min(width / 1920, height / 1080)

            screen: modelData
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            anchors {
                top: true
                right: true
                bottom: true
                left: true
            }

            WlrLayershell.namespace: "nixbox:session-splash"
            WlrLayershell.layer: WlrLayershell.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            mask: Region {
                width: 0
                height: 0
            }

            // Object construction does not mean the layer surface has reached
            // the display. Wait until Quickshell reports that its real backing
            // window is visible, then allow one frame-settle interval.
            Timer {
                interval: root.settleDelayMs
                running: splashWindow.backingWindowVisible && root.startedAt === 0
                repeat: false
                onTriggered: root.beginAnimation()
            }

            Rectangle {
                anchors.fill: parent
                color: "#0b0c0f"
                opacity: root.overlayOpacity

                Image {
                    anchors.centerIn: parent
                    width: parent.width * 0.58
                    height: width
                    source: "nix-snowflake-white.svg"
                    fillMode: Image.PreserveAspectFit
                    opacity: 0.05 * root.watermarkProgress
                    scale: 0.97 + 0.03 * root.watermarkProgress
                    smooth: true
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 44 * splashWindow.layoutScale

                    Row {
                        width: 624 * splashWindow.layoutScale
                        height: 106 * splashWindow.layoutScale

                        Repeater {
                            model: ["N", "I", "X", "B", "O", "X"]

                            Text {
                                required property string modelData

                                width: 104 * splashWindow.layoutScale
                                height: parent.height
                                text: modelData
                                color: "#e9edf4"
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                font.family: "Space Grotesk"
                                font.weight: Font.Light
                                font.pixelSize: 88 * splashWindow.layoutScale
                                opacity: root.wordProgress
                                transform: Translate {
                                    y: 18 * splashWindow.layoutScale * (1 - root.wordProgress)
                                }
                            }
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "STARTING SESSION"
                        color: "#5c6470"
                        font.family: "Space Grotesk"
                        font.weight: Font.Normal
                        font.capitalization: Font.AllUppercase
                        font.pixelSize: 24 * splashWindow.layoutScale
                        font.letterSpacing: 8.16 * splashWindow.layoutScale
                        opacity: root.subtitleProgress
                        transform: Translate {
                            y: 18 * splashWindow.layoutScale * (1 - root.subtitleProgress)
                        }
                    }
                }
            }
        }
    }
}
