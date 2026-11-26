package labelle.android;

import android.app.NativeActivity;
import android.content.Context;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

/**
 * The stock {@link NativeActivity} plus an on-screen keyboard that works.
 *
 * <p>Android 14+ only shows the keyboard for a view that is a text editor
 * ("Ignoring showSoftInput() as view=NativeContentView is not served"), and
 * NativeActivity's content view is not one, so {@code
 * ANativeActivity_showSoftInput} does nothing. This activity adds a hidden
 * 1x1 {@link TextField} that is: native code calls {@link #setTextInput}
 * (from any thread) to show or hide the keyboard, and what the keyboard
 * types reaches native code through {@code nativeCommitText} /
 * {@code nativeDeleteBackward}, registered by labelle-android's
 * {@code src/jni/text_input.c}.
 *
 * <p>Key events (a hardware keyboard, the keyboard's own Backspace or Done
 * sent as keys) still reach the native input queue as before.
 */
public final class LabelleActivity extends NativeActivity {
    /**
     * In the window only while the keyboard is up, so play runs on the stock
     * NativeActivity window.
     */
    private TextField field;

    /** Show (true) or hide (false) the keyboard. Callable from any thread. */
    public void setTextInput(boolean show) {
        runOnUiThread(new SetActive(this, show));
    }

    /** UI thread: add the field, focus it, and show the keyboard once it is attached. */
    private void showKeyboard() {
        if (field == null) {
            field = new TextField(this);
            addContentView(field, new ViewGroup.LayoutParams(1, 1));
        }
        field.requestFocus();
        field.post(new ShowKeyboard(field));
    }

    /** UI thread: hide the keyboard and take the field out of the window. */
    private void hideKeyboard() {
        if (field == null) return;
        InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(field.getWindowToken(), 0);
        ViewGroup parent = (ViewGroup) field.getParent();
        if (parent != null) parent.removeView(field);
        field = null;
    }

    /**
     * {@link #setTextInput} on the UI thread. A named class, not an anonymous
     * one: build-tools 34's d8 crashes on anonymous classes compiled by
     * recent JDKs.
     */
    private static final class SetActive implements Runnable {
        private final LabelleActivity activity;
        private final boolean show;

        SetActive(LabelleActivity activity, boolean show) {
            this.activity = activity;
            this.show = show;
        }

        @Override
        public void run() {
            if (show) {
                activity.showKeyboard();
            } else {
                activity.hideKeyboard();
            }
        }
    }

    /** The show itself, posted so it runs once the field is attached and focused. */
    private static final class ShowKeyboard implements Runnable {
        private final TextField field;

        ShowKeyboard(TextField field) {
            this.field = field;
        }

        @Override
        public void run() {
            field.showKeyboard();
        }
    }

    /** Text the keyboard typed (one character or a whole word). */
    static native void nativeCommitText(String text);

    /** The keyboard erased {@code count} characters before the cursor. */
    static native void nativeDeleteBackward(int count);

    /** The hidden view the keyboard types into. */
    static final class TextField extends View {
        TextField(Context context) {
            super(context);
            setFocusable(true);
            setFocusableInTouchMode(true);
        }

        @Override
        public boolean onCheckIsTextEditor() {
            return true;
        }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo out) {
            // Plain text, no suggestions or autocorrect: the game's field
            // can't show them, and a visible-password variation keeps most
            // keyboards from composing words before committing them.
            out.inputType = InputType.TYPE_CLASS_TEXT
                    | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                    | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            out.imeOptions = EditorInfo.IME_ACTION_DONE
                    | EditorInfo.IME_FLAG_NO_EXTRACT_UI
                    | EditorInfo.IME_FLAG_NO_FULLSCREEN;
            return new Connection(this);
        }

        void showKeyboard() {
            if (!isAttachedToWindow()) return;
            InputMethodManager imm = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm == null) return;
            imm.restartInput(this);
            imm.showSoftInput(this, 0);
        }
    }

    /**
     * Forwards what the keyboard types. A keyboard that still composes (shows
     * a word before committing it) sends the whole word each time it changes:
     * the part already sent is erased first, so the game's field always holds
     * what the keyboard shows.
     */
    static final class Connection extends BaseInputConnection {
        private int composing = 0;

        Connection(View view) {
            super(view, false);
        }

        private void replaceComposing(CharSequence text) {
            if (composing > 0) nativeDeleteBackward(composing);
            composing = 0;
            if (text != null && text.length() > 0) nativeCommitText(text.toString());
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            replaceComposing(text);
            return true;
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            replaceComposing(text);
            composing = text == null ? 0 : text.toString().codePointCount(0, text.length());
            return true;
        }

        @Override
        public boolean finishComposingText() {
            composing = 0;
            return true;
        }

        @Override
        public boolean deleteSurroundingText(int beforeLength, int afterLength) {
            if (beforeLength > 0) nativeDeleteBackward(beforeLength);
            return true;
        }

        @Override
        public boolean performEditorAction(int actionCode) {
            // Done: an Enter key, which the game's key path already handles.
            sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER));
            sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER));
            return true;
        }
    }
}
