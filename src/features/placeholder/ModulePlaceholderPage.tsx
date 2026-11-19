import { PageHeader } from '@/components/layout/AppShell';
import { Card } from '@/components/ui/Card';
import { ComingSoonState } from '@/components/feedback/States';
import type { NavItem } from '@/app/navigation';

/** Halaman sementara untuk modul yang dijadwalkan pada fase berikutnya (tanpa data dummy). */
export default function ModulePlaceholderPage({ item }: { item: NavItem }) {
  return (
    <>
      <PageHeader title={item.label} />
      <Card>
        <ComingSoonState title={item.label} phase={item.phase} />
      </Card>
    </>
  );
}
