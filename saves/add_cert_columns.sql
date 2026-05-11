-- Add certificate columns to listings table
-- Run in Supabase SQL Editor

alter table listings
  add column if not exists cert_auth   boolean not null default false,
  add column if not exists cert_serial boolean not null default false,
  add column if not exists cert_mint   boolean not null default false,
  add column if not exists cert_assay  boolean not null default false;
