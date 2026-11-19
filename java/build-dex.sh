#!/bin/sh
# Rebuild java/classes.dex from java/labelle/android/*.java.
#
# The dex is committed so building an APK needs no JDK: the packager embeds it
# (tools/package/package.zig). Run this after changing the Java, and commit both.
#
# Needs a JDK (javac) and the Android SDK (ANDROID_HOME): platform android-34
# and build-tools 34.0.0, the versions the packager already requires.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
android_jar=$sdk/platforms/android-34/android.jar
d8=$sdk/build-tools/34.0.0/d8
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

javac --release 11 -classpath "$android_jar" -d "$out/classes" "$here"/labelle/android/*.java
"$d8" --release --min-api 28 --lib "$android_jar" --output "$out" $(find "$out/classes" -name '*.class')
cp "$out/classes.dex" "$here/classes.dex"
echo "wrote $here/classes.dex"
