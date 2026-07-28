package com.example.blntextspeech;

import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AlertDialog;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.navigation.fragment.NavHostFragment;
import androidx.recyclerview.widget.ItemTouchHelper;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.example.blntextspeech.data.BookRepository;
import com.example.blntextspeech.databinding.FragmentFirstBinding;
import com.example.blntextspeech.model.Book;
import com.google.android.material.card.MaterialCardView;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class FirstFragment extends Fragment {
    private FragmentFirstBinding binding;
    private BookRepository repository;
    private ExecutorService worker;
    private ActivityResultLauncher<String[]> openBookLauncher;
    private BookAdapter bookAdapter;
    private ItemTouchHelper itemTouchHelper;

    @Override
    public void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        repository = BookRepository.get(requireContext());
        worker = Executors.newSingleThreadExecutor();
        openBookLauncher = registerForActivityResult(new ActivityResultContracts.OpenDocument(), this::importBook);
    }

    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, ViewGroup container, Bundle savedInstanceState) {
        binding = FragmentFirstBinding.inflate(inflater, container, false);
        return binding.getRoot();
    }

    @Override
    public void onViewCreated(@NonNull View view, Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        binding.importButton.setOnClickListener(v ->
                openBookLauncher.launch(new String[]{"application/epub+zip", "application/zip", "*/*"}));
        binding.themeModeButton.setOnClickListener(v -> showThemeModeDialog());
        bookAdapter = new BookAdapter();
        binding.bookList.setLayoutManager(new LinearLayoutManager(requireContext()));
        binding.bookList.setAdapter(bookAdapter);
        itemTouchHelper = new ItemTouchHelper(new BookDragCallback());
        itemTouchHelper.attachToRecyclerView(binding.bookList);
        renderShelf();
    }

    private void showThemeModeDialog() {
        String[] modes = {
                getString(R.string.theme_follow_system),
                getString(R.string.theme_light),
                getString(R.string.theme_dark)
        };
        new AlertDialog.Builder(requireContext())
                .setTitle(R.string.theme_mode)
                .setSingleChoiceItems(modes, ThemeMode.selectedIndex(requireContext()),
                        (dialog, which) -> {
                            dialog.dismiss();
                            ThemeMode.saveAndApply(requireContext(), ThemeMode.modeForIndex(which));
                        })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }

    @Override
    public void onResume() {
        super.onResume();
        if (binding != null) renderShelf();
    }

    private void importBook(Uri uri) {
        if (uri == null || binding == null) return;
        setImporting(true);
        worker.execute(() -> {
            try {
                Book book = repository.importBook(uri);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (binding == null) return;
                    setImporting(false);
                    renderShelf();
                    Toast.makeText(requireContext(), getString(R.string.import_success, book.getTitle()), Toast.LENGTH_SHORT).show();
                });
            } catch (Exception error) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (binding == null) return;
                    setImporting(false);
                    String message = error.getMessage() == null ? getString(R.string.import_failed) : error.getMessage();
                    Toast.makeText(requireContext(), message, Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void setImporting(boolean importing) {
        binding.importButton.setEnabled(!importing);
        binding.importProgress.setVisibility(importing ? View.VISIBLE : View.GONE);
        binding.importHint.setText(importing ? R.string.importing : R.string.import_hint);
    }

    private void renderShelf() {
        List<Book> books = repository.getBooks();
        bookAdapter.setBooks(books);
        binding.emptyShelf.setVisibility(books.isEmpty() ? View.VISIBLE : View.GONE);
        binding.bookCount.setText(getResources().getQuantityString(R.plurals.book_count, books.size(), books.size()));
    }

    private void openBook(Book book) {
        repository.moveBookToFront(book.getId());
        Bundle arguments = new Bundle();
        arguments.putString(SecondFragment.ARG_BOOK_ID, book.getId());
        NavHostFragment.findNavController(this)
                .navigate(R.id.action_FirstFragment_to_SecondFragment, arguments);
    }

    private void confirmDelete(Book book) {
        new AlertDialog.Builder(requireContext())
                .setTitle(R.string.delete_book_title)
                .setMessage(getString(R.string.delete_book_message, book.getTitle()))
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.delete, (dialog, which) -> {
                    if (repository.deleteBook(book.getId())) {
                        renderShelf();
                        Toast.makeText(requireContext(), R.string.book_deleted, Toast.LENGTH_SHORT).show();
                    } else {
                        Toast.makeText(requireContext(), R.string.delete_book_failed, Toast.LENGTH_SHORT).show();
                    }
                })
                .show();
    }

    private final class BookAdapter extends RecyclerView.Adapter<BookViewHolder> {
        private final List<Book> books = new ArrayList<>();
        private String editingBookId;

        void setBooks(List<Book> updatedBooks) {
            books.clear();
            books.addAll(updatedBooks);
            if (editingBookId != null && findPosition(editingBookId) < 0) editingBookId = null;
            notifyDataSetChanged();
        }

        @NonNull
        @Override
        public BookViewHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            return new BookViewHolder();
        }

        @Override
        public void onBindViewHolder(@NonNull BookViewHolder holder, int position) {
            holder.bind(books.get(position));
        }

        @Override
        public int getItemCount() {
            return books.size();
        }

        void enterEditMode(BookViewHolder holder, Book book) {
            int previous = findPosition(editingBookId);
            editingBookId = book.getId();
            if (previous >= 0 && previous != holder.getBindingAdapterPosition()) {
                notifyItemChanged(previous);
            }
            holder.deleteButton.setVisibility(View.VISIBLE);
            itemTouchHelper.startDrag(holder);
        }

        void move(int from, int to) {
            Book moved = books.remove(from);
            books.add(to, moved);
            notifyItemMoved(from, to);
            repository.moveBook(from, to);
        }

        private int findPosition(String id) {
            if (id == null) return -1;
            for (int i = 0; i < books.size(); i++) {
                if (books.get(i).getId().equals(id)) return i;
            }
            return -1;
        }
    }

    private final class BookViewHolder extends RecyclerView.ViewHolder {
        private final MaterialCardView card;
        private final TextView title;
        private final TextView author;
        private final TextView progress;
        private final TextView deleteButton;

        BookViewHolder() {
            super(new FrameLayout(requireContext()));
            FrameLayout root = (FrameLayout) itemView;
            RecyclerView.LayoutParams rootParams = new RecyclerView.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            rootParams.setMargins(0, 0, 0, dp(8));
            root.setLayoutParams(rootParams);
            root.setPadding(0, dp(4), dp(4), 0);

            card = new MaterialCardView(requireContext());
            FrameLayout.LayoutParams cardParams = new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            cardParams.setMargins(0, dp(4), dp(4), 0);
            card.setLayoutParams(cardParams);
            card.setClickable(true);
            card.setFocusable(true);
            card.setStrokeWidth(dp(1));
            card.setStrokeColor(ContextCompat.getColor(requireContext(), R.color.shelf_outline));
            card.setCardBackgroundColor(ContextCompat.getColor(requireContext(), R.color.app_background));
            card.setRadius(dp(14));

            LinearLayout content = new LinearLayout(requireContext());
            content.setOrientation(LinearLayout.VERTICAL);
            content.setPadding(dp(16), dp(16), dp(48), dp(16));

            title = new TextView(requireContext());
            title.setTextSize(18);
            title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
            title.setTextColor(ContextCompat.getColor(requireContext(), R.color.reader_text));
            title.setMaxLines(2);

            author = new TextView(requireContext());
            author.setTextSize(14);
            author.setTextColor(ContextCompat.getColor(requireContext(), R.color.secondary_text));
            author.setPadding(0, dp(6), 0, 0);

            progress = new TextView(requireContext());
            progress.setTextSize(13);
            progress.setTextColor(ContextCompat.getColor(requireContext(), R.color.brand));
            progress.setPadding(0, dp(10), 0, 0);

            content.addView(title);
            content.addView(author);
            content.addView(progress);
            card.addView(content);

            deleteButton = new TextView(requireContext());
            FrameLayout.LayoutParams deleteParams = new FrameLayout.LayoutParams(dp(40), dp(40));
            deleteParams.gravity = android.view.Gravity.TOP | android.view.Gravity.END;
            deleteButton.setLayoutParams(deleteParams);
            deleteButton.setGravity(android.view.Gravity.CENTER);
            deleteButton.setText("\u00D7");
            deleteButton.setTextSize(25);
            deleteButton.setTextColor(ContextCompat.getColor(requireContext(), android.R.color.white));
            deleteButton.setContentDescription(getString(R.string.delete_book));
            GradientDrawable deleteBackground = new GradientDrawable();
            deleteBackground.setShape(GradientDrawable.OVAL);
            deleteBackground.setColor(ContextCompat.getColor(requireContext(), android.R.color.holo_red_dark));
            deleteButton.setBackground(deleteBackground);
            deleteButton.setElevation(dp(6));

            root.addView(card);
            root.addView(deleteButton);
        }

        void bind(Book book) {
            title.setText(book.getTitle());
            author.setText(getString(R.string.book_author, book.getAuthor()));
            progress.setText(book.getLastPage() > 0
                    ? getString(R.string.continue_page, book.getLastPage() + 1)
                    : getString(R.string.tap_to_read));
            deleteButton.setVisibility(book.getId().equals(bookAdapter.editingBookId)
                    ? View.VISIBLE : View.GONE);
            card.setOnClickListener(v -> openBook(book));
            card.setOnLongClickListener(v -> {
                v.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS);
                bookAdapter.enterEditMode(this, book);
                return true;
            });
            deleteButton.setOnClickListener(v -> confirmDelete(book));
        }
    }

    private final class BookDragCallback extends ItemTouchHelper.SimpleCallback {
        BookDragCallback() {
            super(ItemTouchHelper.UP | ItemTouchHelper.DOWN, 0);
        }

        @Override
        public boolean isLongPressDragEnabled() {
            return false;
        }

        @Override
        public boolean onMove(@NonNull RecyclerView recyclerView,
                              @NonNull RecyclerView.ViewHolder source,
                              @NonNull RecyclerView.ViewHolder target) {
            int from = source.getBindingAdapterPosition();
            int to = target.getBindingAdapterPosition();
            if (from < 0 || to < 0 || from == to) return false;
            bookAdapter.move(from, to);
            return true;
        }

        @Override
        public void onSwiped(@NonNull RecyclerView.ViewHolder viewHolder, int direction) {
            // Swipe deletion is intentionally disabled; use the visible delete button.
        }

        @Override
        public void onSelectedChanged(@Nullable RecyclerView.ViewHolder viewHolder, int actionState) {
            super.onSelectedChanged(viewHolder, actionState);
            if (viewHolder != null && actionState == ItemTouchHelper.ACTION_STATE_DRAG) {
                viewHolder.itemView.setAlpha(0.86f);
                viewHolder.itemView.setScaleX(1.02f);
                viewHolder.itemView.setScaleY(1.02f);
            }
        }

        @Override
        public void clearView(@NonNull RecyclerView recyclerView,
                              @NonNull RecyclerView.ViewHolder viewHolder) {
            super.clearView(recyclerView, viewHolder);
            viewHolder.itemView.setAlpha(1f);
            viewHolder.itemView.setScaleX(1f);
            viewHolder.itemView.setScaleY(1f);
        }
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    public void onDestroyView() {
        super.onDestroyView();
        itemTouchHelper = null;
        bookAdapter = null;
        binding = null;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        worker.shutdownNow();
    }
}
