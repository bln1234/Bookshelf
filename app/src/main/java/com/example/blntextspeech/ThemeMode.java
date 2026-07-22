package com.example.blntextspeech;

import android.content.Context;

import androidx.appcompat.app.AppCompatDelegate;

/** Persists and applies the application's light/dark appearance preference. */
final class ThemeMode {
    private static final String PREFERENCES = "appearance";
    private static final String KEY_NIGHT_MODE = "night_mode";

    private ThemeMode() {}

    static int getSavedMode(Context context) {
        return context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .getInt(KEY_NIGHT_MODE, AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM);
    }

    static void applySavedMode(Context context) {
        AppCompatDelegate.setDefaultNightMode(getSavedMode(context));
    }

    static void saveAndApply(Context context, int mode) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .putInt(KEY_NIGHT_MODE, mode)
                .apply();
        AppCompatDelegate.setDefaultNightMode(mode);
    }

    static int selectedIndex(Context context) {
        int mode = getSavedMode(context);
        if (mode == AppCompatDelegate.MODE_NIGHT_NO) return 1;
        if (mode == AppCompatDelegate.MODE_NIGHT_YES) return 2;
        return 0;
    }

    static int modeForIndex(int index) {
        if (index == 1) return AppCompatDelegate.MODE_NIGHT_NO;
        if (index == 2) return AppCompatDelegate.MODE_NIGHT_YES;
        return AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM;
    }
}
