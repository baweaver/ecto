defmodule Ecto.Associations.Assoc do
  @moduledoc false

  @doc """
  Transforms a result set based on query assocs, loading
  the associations onto their parent model.
  """
  @spec query([Ecto.Model.t], Ecto.Query.t) :: [Ecto.Model.t]
  def query(rows, query)

  def query([], _query) do
    []
  end

  def query(rows, %{assocs: []}) do
    rows
  end

  def query(rows, %{assocs: assocs, sources: sources}) do
    # Pre-create rose tree of reflections and accumulator
    # dicts in the same structure as the fields tree
    refls = create_refls(0, assocs, sources)
    accs  = create_accs(assocs)

    # Replace the dict in the accumulator by a list
    # We use it as a flag to store the substructs
    accs = put_elem(accs, 1, [])

    # Populate tree of dicts of associated entities from the result set
    {_keys, rows, sub_dicts} = Enum.reduce(rows, accs, fn row, acc ->
      merge(row, acc, 0) |> elem(0)
    end)

    # Retrieve and load the assocs from cached dictionaries recursively
    for {item, sub_structs} <- Enum.reverse(rows) do
      [load_assocs(item, sub_dicts, refls)|sub_structs]
    end
  end

  defp merge([struct|sub_structs], {keys, dict, sub_dicts}, parent_key) do
    if struct do
      child_key = Ecto.Model.primary_key(struct) ||
                    raise Ecto.NoPrimaryKeyError, model: struct.__struct__
    end

    # Traverse sub_structs adding one by one to the tree.
    # Note we need to traverse even if we don't have a child_key
    # due to nested associations.
    {sub_dicts, sub_structs} =
      Enum.map_reduce sub_dicts, sub_structs, &merge(&2, &1, child_key)

    # Now if we have a struct and its parent key, we store the current
    # data unless we have already processed it.
    cache = {parent_key, child_key}

    if struct && parent_key && not HashSet.member?(keys, cache) do
      keys = HashSet.put(keys, cache)
      item = {child_key, struct}

      # If we have a list, we are at the root,
      # so we also store the sub structs
      dict =
        if is_list(dict) do
          [{item, sub_structs}|dict]
        else
          HashDict.update(dict, parent_key, [item], &[item|&1])
        end
    end

    {{keys, dict, sub_dicts}, sub_structs}
  end

  defp load_assocs({child_key, struct}, sub_dicts, refls) do
    Enum.reduce :lists.zip(sub_dicts, refls), struct, fn
      {{_keys, dict, sub_dicts}, {refl, refls}}, acc ->
        loaded =
          dict
          |> HashDict.get(child_key, [])
          |> Enum.reverse()
          |> Enum.map(&load_assocs(&1, sub_dicts, refls))

        # TODO: Do not hardcode
        unless refl.__struct__ == Ecto.Associations.HasMany do
          loaded = List.first(loaded)
        end

        Map.put(acc, refl.field, loaded)
    end
  end

  defp create_refls(idx, fields, sources) do
    Enum.map(fields, fn {field, {child_idx, child_fields}} ->
      {_source, model} = elem(sources, idx)
      {model.__schema__(:association, field),
       create_refls(child_idx, child_fields, sources)}
    end)
  end

  defp create_accs(fields) do
    acc = Enum.map(fields, fn {_field, {_child_idx, child_fields}} ->
      create_accs(child_fields)
    end)

    {HashSet.new, HashDict.new, acc}
  end
end
