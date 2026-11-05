import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { useEffect, useState } from "react";
import { label, listSpaces, moveAndReport, Space } from "./spacemove";

export default function Command() {
  const [spaces, setSpaces] = useState<Space[]>();
  const [error, setError] = useState<string>();

  useEffect(() => {
    listSpaces()
      .then((all) => setSpaces(all.filter((space) => !space.fullscreen)))
      .catch((e: Error) => setError(e.message));
  }, []);

  return (
    <List
      isLoading={!spaces && !error}
      searchBarPlaceholder="Send the focused window to…"
      // Raycast's footer shows only the primary action on the right; the left slot is ours.
      navigationTitle="Send and Stay  ⌘↵"
    >
      {error ? <List.EmptyView icon={Icon.Warning} title="Couldn't read Spaces" description={error} /> : null}
      {spaces?.map((space) => {
        const id = String(space.id);
        const accessories: List.Item.Accessory[] = space.active
          ? [{ tag: { value: "Current", color: Color.Green } }]
          : [];
        return (
          <List.Item
            key={id}
            id={id}
            title={label(space)}
            keywords={[String(space.number), ...(space.name?.split(/[\s/]+/) ?? [])]}
            subtitle={space.displayIndex > 1 ? `Display ${space.displayIndex}` : undefined}
            accessories={accessories}
            actions={
              <ActionPanel>
                <Action title="Send and Follow" icon={Icon.ArrowRightCircle} onAction={() => moveAndReport(`id:${id}`, true)} />
                {/* The second action gets ⌘↵ from Raycast. */}
                <Action title="Send and Stay" icon={Icon.ArrowRight} onAction={() => moveAndReport(`id:${id}`, false)} />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
