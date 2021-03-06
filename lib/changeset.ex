defmodule Changeset do
  import DefMemo

  @moduledoc """
  The Changeset module allows for calculating the Levenshtein distance between
  two lists or binaries, or the actual edit steps required to go from one to the other.
  """

  @doc """
  Calculate the minimal steps (insertions, deletions, substitutions and moves)
  required to turn one given list or binary into another.

  ## Examples

      iex> taylor_swift_songs = [22, 15, "I Knew You Were Trouble"]
      [22, 15, "I Knew You Were Trouble"]
      iex> positive_integers = [22, 7, 15, 186, 33]
      [22, 7, 15, 186, 33]
      iex> Changeset.edits(taylor_swift_songs, positive_integers)
      [{:insert, 7, 1}, {:substitute, 186, 3}, {:insert, 33, 4}]
      iex> Changeset.edits(positive_integers, taylor_swift_songs)
      [{:delete, 7, 1}, {:substitute, "I Knew You Were Trouble", 2}, {:delete, 33, 4}]

  It also supports moves, each of which is really only a deletion followed by an
  insertion.

      iex> Changeset.edits(~w( a v e r y ), ~w( g a r v e y ))
      [{:insert, "g", 0}, {:move, "r", 3, 2}]

  """
  @spec edits(binary | [], binary | []) :: [tuple]
  def edits(source, target) do
    edits(source, target, fn _type, _value, _idx -> 1 end)
  end

  @doc """
  Calculate the minimal steps (insertions, deletions, substitutions and moves)
  required to turn one given list or binary into another using a custom cost
  function, which takes an edit type (`:insert`, `:delete` or `:substitute`), a
  value and an index and returns a cost (i.e. an integer).

  (Note that the cost function is applied *before* insertions and deletions are
  converted into moves, meaning it will never receive a `:move` edit as an
  argument.)

  ## Examples

  For instance, making substitutions more costly will result in the algorithm
  replacing them with insertions and deletions instead.

      iex> Changeset.edits(~w( a b c ), ~w( a d c ))
      [{:substitute, "d", 1}]
      iex> Changeset.edits(~w( a b c ), ~w( a d c ), fn type, _value, _idx ->
      ...>   if type == :substitute, do: 3, else: 1
      ...> end)
      [{:insert, "d", 1}, {:delete, "b", 1}]

  """
  @spec edits(binary | [], binary | [], (atom, any, non_neg_integer -> number)) :: [tuple]
  def edits(source, target, cost_func) when is_binary(source), do: edits(source |> String.codepoints, target, cost_func)
  def edits(source, target, cost_func) when is_binary(target), do: edits(source, target |> String.codepoints, cost_func)
  def edits(source, target, cost_func) do
    DefMemo.start_link # Necessary for memoization to work.
    {res, _} = do_edits(Enum.reverse(source), Enum.reverse(target), cost_func)
    res |> Enum.reverse |> reduce_moves
  end

  @doc false
  defmemo do_edits([], [], cost_func), do: {[], 0}
  defmemo do_edits([src_hd | src], [], cost_func) do
    edit = {:delete, src_hd, length(src)}
    {res, cost} = do_edits(src, [], cost_func)
    {[edit | res], cost + calc_cost(edit, cost_func)}
  end
  defmemo do_edits([], [tgt_hd | tgt], cost_func) do
    edit = {:insert, tgt_hd, length(tgt)}
    {res, cost} = do_edits([], tgt, cost_func)
    {[edit | res], cost + calc_cost(edit, cost_func)}
  end
  defmemo do_edits([src_hd | src], [tgt_hd | tgt], cost_func) do
    if src_hd == tgt_hd do
      do_edits(src, tgt, cost_func)
    else
      [
        do_edits(src, [tgt_hd] ++ tgt, cost_func),
        do_edits([src_hd] ++ src, tgt, cost_func),
        do_edits(src, tgt, cost_func)
      ]
      |> Enum.zip([
        {:delete, src_hd, length(src)},
        {:insert, tgt_hd, length(tgt)},
        {:substitute, tgt_hd, length(tgt)}
      ])
      |> Enum.map(fn {{res, cost}, edit} ->
        {[edit | res], cost + calc_cost(edit, cost_func)}
      end)
      |> Enum.min_by(fn {_, cost} -> cost end)
    end
  end

  # Calculates the cost for a given action using a given cost function.
  defp calc_cost({type, value, idx}, cost_func), do: cost_func.(type, value, idx)

  # Reduces a list of action steps to combine insertions and deletions of the
  # same value into a single :move action with that value. (These are equivalent
  # anyway, as a deletion and insertion elsewhere of a certain value is nothing
  # more than a movement of that value.)
  defp reduce_moves(edit_steps) do
    edit_steps
    |> Enum.reduce([], fn step, acc ->
      move = move_from_steps(edit_steps, step)
      if move != nil, do: acc ++ [move], else: acc ++ [step]
    end)
    |> Enum.uniq
  end

  # Takes an edit step and a list of edit steps and returns either a move step
  # if there is one to be found for that edit step, or nil if not.
  defp move_from_steps(edit_steps, step) do
    case elem(step, 0) do
      :insert ->
        find_move(edit_steps, step, :delete)
      :delete ->
        find_move(edit_steps, step, :insert)
      _ ->
        nil
    end
  end

  defp find_move(steps, {type, value, idx}, other_type) do
    # Find the other edit step (i.e. an insertion if the step is a deletion, or
    # a deletion if the step is an insertion).
    other = Enum.find(steps, fn {t, v, _} ->
      t == other_type && v == value
    end)

    # If another edit step was found, create a tuple representing a move based
    # on those two edit steps.
    if other != nil do
      origin_idx = if type == :insert, do: elem(other, 2), else: idx
      destination_idx = if type == :insert, do: idx, else: elem(other, 2)
      {:move, value, origin_idx, destination_idx}
    else
      nil
    end
  end

  @doc """
  Calculate the Levenshtein distance between two lists, i.e. how many
  insertions, deletions or substitutions are required to turn one given list
  into another.

  ## Examples

      iex> taylor_swift_songs = [22, 15, "I Knew You Were Trouble"]
      [22, 15, "I Knew You Were Trouble"]
      iex> positive_integers = [22, 7, 15, 186, 33]
      [22, 7, 15, 186, 33]
      iex> Changeset.levenshtein(taylor_swift_songs, positive_integers)
      3

  """
  @spec levenshtein(binary | [], binary | []) :: non_neg_integer
  def levenshtein(source, target) when is_binary(source), do: levenshtein(source |> String.codepoints, target)
  def levenshtein(source, target) when is_binary(target), do: levenshtein(source, target |> String.codepoints)
  def levenshtein(source, target) do
    DefMemo.start_link # Necessary for memoization to work.
    do_levenshtein(Enum.reverse(source), Enum.reverse(target))
  end

  @doc false
  defmemo do_levenshtein(source, []), do: length(source)
  defmemo do_levenshtein([], target), do: length(target)
  defmemo do_levenshtein([src_hd | source], [tgt_hd | target]) do
    if src_hd == tgt_hd do
      do_levenshtein(source, target)
    else
      Enum.min([
        do_levenshtein(source, [tgt_hd | target]) + 1,
        do_levenshtein([src_hd | source], target) + 1,
        do_levenshtein(source, target) + 1
      ])
    end
  end
end
