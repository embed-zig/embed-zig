pub inline fn pageSize() usize {
    // ESP heap is not paged; byte granularity satisfies embed's heap contract.
    return 1;
}
