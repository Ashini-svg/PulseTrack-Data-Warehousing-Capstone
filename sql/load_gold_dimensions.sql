-- ============================================================
-- PulseTrack: Gold Dimension Loading
-- Loads 10 dimensions from verified Silver data.
-- Includes advertiser SCD Type 2 history.
-- ============================================================


-- ============================================================
-- 1. DATE DIMENSION
-- ============================================================

WITH source_dates AS (
    SELECT
        MIN((impression_time AT TIME ZONE 'UTC')::date) AS first_date,
        MAX((impression_time AT TIME ZONE 'UTC')::date) AS last_date
    FROM silver.impressions

    UNION ALL

    SELECT
        MIN((click_time AT TIME ZONE 'UTC')::date),
        MAX((click_time AT TIME ZONE 'UTC')::date)
    FROM silver.clicks

    UNION ALL

    SELECT
        MIN((conversion_time AT TIME ZONE 'UTC')::date),
        MAX((conversion_time AT TIME ZONE 'UTC')::date)
    FROM silver.conversion_history

    UNION ALL

    SELECT
        MIN((adjusted_at AT TIME ZONE 'UTC')::date),
        MAX((adjusted_at AT TIME ZONE 'UTC')::date)
    FROM silver.revenue_adjustments
),
bounds AS (
    SELECT
        MIN(first_date) AS first_date,
        MAX(last_date) AS last_date
    FROM source_dates
)
INSERT INTO gold.dim_date (
    full_date, year_number, quarter_number,
    month_number, month_name, day_of_month, day_of_week
)
SELECT
    day_value::date,
    EXTRACT(YEAR FROM day_value)::integer,
    EXTRACT(QUARTER FROM day_value)::smallint,
    EXTRACT(MONTH FROM day_value)::smallint,
    TO_CHAR(day_value, 'FMMonth'),
    EXTRACT(DAY FROM day_value)::smallint,
    EXTRACT(ISODOW FROM day_value)::smallint
FROM bounds
CROSS JOIN LATERAL GENERATE_SERIES(
    bounds.first_date::timestamp,
    bounds.last_date::timestamp,
    INTERVAL '1 day'
) AS dates(day_value)
ON CONFLICT (full_date) DO NOTHING;


-- ============================================================
-- 2. ACCOUNT MANAGER DIMENSION
-- ============================================================

INSERT INTO gold.dim_account_manager (
    account_manager_id, manager_name, team, region
)
SELECT
    am_id, am_name, team, region
FROM silver.account_managers
WHERE am_id IS NOT NULL
ON CONFLICT (account_manager_id)
DO UPDATE SET
    manager_name = EXCLUDED.manager_name,
    team = EXCLUDED.team,
    region = EXCLUDED.region
WHERE (
    gold.dim_account_manager.manager_name,
    gold.dim_account_manager.team,
    gold.dim_account_manager.region
) IS DISTINCT FROM (
    EXCLUDED.manager_name,
    EXCLUDED.team,
    EXCLUDED.region
);


-- ============================================================
-- 3. ADVERTISER DIMENSION - SCD TYPE 2
-- ============================================================

-- Stage complete historical versions before merging.
CREATE TEMP TABLE desired_advertiser_versions (
    advertiser_id TEXT NOT NULL,
    advertiser_name TEXT,
    vertical TEXT,
    account_manager_key BIGINT,
    billing_country TEXT,
    billing_currency TEXT,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,
    is_current BOOLEAN NOT NULL,
    PRIMARY KEY (advertiser_id, effective_from),
    CHECK (
        effective_to IS NULL
        OR effective_to > effective_from
    )
) ON COMMIT DROP;

WITH raw_history AS (
    SELECT
        a.advertiser_id,
        a.advertiser_name,
        a.vertical,
        COALESCE(p.billing_country, a.billing_country)
            AS billing_country,
        p.billing_currency,

        NULLIF(BTRIM(history.item->>'am_id'), '')
            AS history_manager_id,

        NULLIF(history.item->>'from', '')::date
            AS start_date,

        NULLIF(history.item->>'to', '')::date
            AS last_date

    FROM silver.advertisers a

    JOIN silver.advertiser_profiles p
        ON p.advertiser_id = a.advertiser_id

    CROSS JOIN LATERAL JSONB_ARRAY_ELEMENTS(
        CASE
            WHEN JSONB_TYPEOF(p.account_manager_history) = 'array'
                THEN p.account_manager_history
            ELSE '[]'::jsonb
        END
    ) AS history(item)
),
ordered_history AS (
    SELECT
        *,
        LEAD(start_date) OVER (
            PARTITION BY advertiser_id
            ORDER BY start_date
        ) AS next_start_date
    FROM raw_history
),
history_versions AS (
    SELECT
        advertiser_id,
        advertiser_name,
        vertical,
        history_manager_id,
        billing_country,
        billing_currency,

        start_date::timestamp AT TIME ZONE 'UTC'
            AS effective_from,

        (
            CASE
                WHEN next_start_date IS NOT NULL
                     AND last_date IS NOT NULL
                    THEN LEAST(next_start_date, last_date + 1)

                WHEN next_start_date IS NOT NULL
                    THEN next_start_date

                WHEN last_date IS NOT NULL
                    THEN last_date + 1

                ELSE NULL
            END
        )::timestamp AT TIME ZONE 'UTC'
            AS effective_to

    FROM ordered_history
),
all_versions AS (
    -- Preserve versions explicitly supplied in JSONL.
    SELECT *
    FROM history_versions

    UNION ALL

    -- Fallback only when an advertiser has no history.
    SELECT
        a.advertiser_id,
        a.advertiser_name,
        a.vertical,
        a.account_manager_id,
        COALESCE(p.billing_country, a.billing_country),
        p.billing_currency,

        COALESCE(
            a.signup_date::timestamp AT TIME ZONE 'UTC',
            a.created_at
        ) AS effective_from,

        NULL::timestamptz AS effective_to

    FROM silver.advertisers a
    LEFT JOIN silver.advertiser_profiles p
        ON p.advertiser_id = a.advertiser_id

    WHERE NOT EXISTS (
        SELECT 1
        FROM raw_history h
        WHERE h.advertiser_id = a.advertiser_id
    )
)
INSERT INTO desired_advertiser_versions (
    advertiser_id, advertiser_name, vertical,
    account_manager_key, billing_country, billing_currency,
    effective_from, effective_to, is_current
)
SELECT
    v.advertiser_id,
    v.advertiser_name,
    v.vertical,
    am.account_manager_key,
    v.billing_country,
    v.billing_currency,
    v.effective_from,
    v.effective_to,
    v.effective_to IS NULL

FROM all_versions v
LEFT JOIN gold.dim_account_manager am
    ON am.account_manager_id = v.history_manager_id;

-- Check the historical version structure before merging.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM desired_advertiser_versions
        GROUP BY advertiser_id
        HAVING COUNT(*) FILTER (WHERE is_current) <> 1
    ) THEN
        RAISE EXCEPTION
            'Advertiser SCD validation failed: expected one current version per advertiser';
    END IF;

    IF (
        SELECT COUNT(DISTINCT advertiser_id)
        FROM desired_advertiser_versions
    ) <> (
        SELECT COUNT(*)
        FROM silver.advertisers
    ) THEN
        RAISE EXCEPTION
            'Advertiser SCD validation failed: missing advertiser history';
    END IF;
END $$;

-- Close existing versions that are no longer current.
UPDATE gold.dim_advertiser d
SET
    effective_to = s.effective_to,
    is_current = FALSE
FROM desired_advertiser_versions s
WHERE d.advertiser_id = s.advertiser_id
  AND d.effective_from = s.effective_from
  AND d.is_current = TRUE
  AND s.is_current = FALSE;

-- Close an earlier current version when a newer one arrives.
UPDATE gold.dim_advertiser d
SET
    effective_to = s.effective_from,
    is_current = FALSE
FROM desired_advertiser_versions s
WHERE d.advertiser_id = s.advertiser_id
  AND d.is_current = TRUE
  AND s.is_current = TRUE
  AND d.effective_from < s.effective_from;

-- Insert historical versions and update changed attributes.
INSERT INTO gold.dim_advertiser (
    advertiser_id, advertiser_name, vertical,
    account_manager_key, billing_country, billing_currency,
    effective_from, effective_to, is_current
)
SELECT
    advertiser_id, advertiser_name, vertical,
    account_manager_key, billing_country, billing_currency,
    effective_from, effective_to, is_current
FROM desired_advertiser_versions
ORDER BY advertiser_id, effective_from

ON CONFLICT (advertiser_id, effective_from)
DO UPDATE SET
    advertiser_name = EXCLUDED.advertiser_name,
    vertical = EXCLUDED.vertical,
    account_manager_key = EXCLUDED.account_manager_key,
    billing_country = EXCLUDED.billing_country,
    billing_currency = EXCLUDED.billing_currency,
    effective_to = EXCLUDED.effective_to,
    is_current = EXCLUDED.is_current

WHERE (
    gold.dim_advertiser.advertiser_name,
    gold.dim_advertiser.vertical,
    gold.dim_advertiser.account_manager_key,
    gold.dim_advertiser.billing_country,
    gold.dim_advertiser.billing_currency,
    gold.dim_advertiser.effective_to,
    gold.dim_advertiser.is_current
) IS DISTINCT FROM (
    EXCLUDED.advertiser_name,
    EXCLUDED.vertical,
    EXCLUDED.account_manager_key,
    EXCLUDED.billing_country,
    EXCLUDED.billing_currency,
    EXCLUDED.effective_to,
    EXCLUDED.is_current
);

-- ============================================================
-- Inferred advertiser history for earlier source events.
--
-- The advertiser identity is known from the campaign.
-- The historical manager is unknown, not guessed.
-- 1900-01-01 is a technical coverage boundary,
-- NOT a claimed real-world assignment start date.
-- ============================================================

WITH first_known_version AS (
    SELECT DISTINCT ON (advertiser_id)
        advertiser_id,
        advertiser_name,
        vertical,
        billing_country,
        billing_currency,
        effective_from
    FROM desired_advertiser_versions
    ORDER BY advertiser_id, effective_from
),
earlier_activity AS (
    SELECT c.advertiser_id
    FROM silver.impressions i
    JOIN silver.campaigns c
        ON c.campaign_id = i.campaign_id
    JOIN first_known_version v
        ON v.advertiser_id = c.advertiser_id
    WHERE i.impression_time < v.effective_from

    UNION

    SELECT c.advertiser_id
    FROM silver.clicks cl
    JOIN silver.campaigns c
        ON c.campaign_id = cl.campaign_id
    JOIN first_known_version v
        ON v.advertiser_id = c.advertiser_id
    WHERE cl.click_time < v.effective_from

    UNION

    SELECT c.advertiser_id
    FROM silver.conversion_history h
    JOIN silver.campaigns c
        ON c.campaign_id = h.campaign_id
    JOIN first_known_version v
        ON v.advertiser_id = c.advertiser_id
    WHERE h.conversion_time < v.effective_from
)
INSERT INTO gold.dim_advertiser AS target (
    advertiser_id,
    advertiser_name,
    vertical,
    account_manager_key,
    billing_country,
    billing_currency,
    effective_from,
    effective_to,
    is_current,
    is_inferred
)
SELECT
    v.advertiser_id,
    v.advertiser_name,
    v.vertical,
    NULL,
    v.billing_country,
    v.billing_currency,
    TIMESTAMPTZ '1900-01-01 00:00:00+00',
    v.effective_from,
    FALSE,
    TRUE
FROM first_known_version v
JOIN earlier_activity e
    ON e.advertiser_id = v.advertiser_id
WHERE v.effective_from >
      TIMESTAMPTZ '1900-01-01 00:00:00+00'

ON CONFLICT (advertiser_id, effective_from)
DO UPDATE SET
    advertiser_name = EXCLUDED.advertiser_name,
    vertical = EXCLUDED.vertical,
    account_manager_key = NULL,
    billing_country = EXCLUDED.billing_country,
    billing_currency = EXCLUDED.billing_currency,
    effective_to = EXCLUDED.effective_to,
    is_current = FALSE,
    is_inferred = TRUE
WHERE (
    target.advertiser_name,
    target.vertical,
    target.account_manager_key,
    target.billing_country,
    target.billing_currency,
    target.effective_to,
    target.is_current,
    target.is_inferred
) IS DISTINCT FROM (
    EXCLUDED.advertiser_name,
    EXCLUDED.vertical,
    NULL,
    EXCLUDED.billing_country,
    EXCLUDED.billing_currency,
    EXCLUDED.effective_to,
    FALSE,
    TRUE
);


-- ============================================================
-- 4. PARTNER DIMENSION
-- ============================================================

INSERT INTO gold.dim_partner (
    partner_id, partner_name, profile_data
)
SELECT
    p.partner_id,
    p.partner_name,
    pp.profile_data
FROM silver.partners p
LEFT JOIN silver.partner_profiles pp
    ON pp.matched_partner_id = p.partner_id

ON CONFLICT (partner_id)
DO UPDATE SET
    partner_name = EXCLUDED.partner_name,
    profile_data = EXCLUDED.profile_data

WHERE (
    gold.dim_partner.partner_name,
    gold.dim_partner.profile_data
) IS DISTINCT FROM (
    EXCLUDED.partner_name,
    EXCLUDED.profile_data
);


-- ============================================================
-- 5. OFFER DIMENSION
-- ============================================================

INSERT INTO gold.dim_offer (
    offer_id, offer_name, advertiser_id
)
SELECT
    offer_id, offer_name, advertiser_id
FROM silver.offers

ON CONFLICT (offer_id)
DO UPDATE SET
    offer_name = EXCLUDED.offer_name,
    advertiser_id = EXCLUDED.advertiser_id

WHERE (
    gold.dim_offer.offer_name,
    gold.dim_offer.advertiser_id
) IS DISTINCT FROM (
    EXCLUDED.offer_name,
    EXCLUDED.advertiser_id
);


-- ============================================================
-- 6. CAMPAIGN DIMENSION
-- ============================================================

INSERT INTO gold.dim_campaign (
    campaign_id, campaign_name, advertiser_id, offer_key
)
SELECT
    c.campaign_id,
    c.campaign_name,
    c.advertiser_id,
    o.offer_key
FROM silver.campaigns c
LEFT JOIN gold.dim_offer o
    ON o.offer_id = c.offer_id

ON CONFLICT (campaign_id)
DO UPDATE SET
    campaign_name = EXCLUDED.campaign_name,
    advertiser_id = EXCLUDED.advertiser_id,
    offer_key = EXCLUDED.offer_key

WHERE (
    gold.dim_campaign.campaign_name,
    gold.dim_campaign.advertiser_id,
    gold.dim_campaign.offer_key
) IS DISTINCT FROM (
    EXCLUDED.campaign_name,
    EXCLUDED.advertiser_id,
    EXCLUDED.offer_key
);


-- ============================================================
-- 7. CREATIVE DIMENSION
-- ============================================================

INSERT INTO gold.dim_creative (
    creative_id, creative_name,
    creative_format, creative_size, campaign_key
)
SELECT
    c.creative_id,
    c.creative_name,
    c.format,
    c.size,
    cam.campaign_key
FROM silver.creatives c
LEFT JOIN gold.dim_campaign cam
    ON cam.campaign_id = c.campaign_id

ON CONFLICT (creative_id)
DO UPDATE SET
    creative_name = EXCLUDED.creative_name,
    creative_format = EXCLUDED.creative_format,
    creative_size = EXCLUDED.creative_size,
    campaign_key = EXCLUDED.campaign_key

WHERE (
    gold.dim_creative.creative_name,
    gold.dim_creative.creative_format,
    gold.dim_creative.creative_size,
    gold.dim_creative.campaign_key
) IS DISTINCT FROM (
    EXCLUDED.creative_name,
    EXCLUDED.creative_format,
    EXCLUDED.creative_size,
    EXCLUDED.campaign_key
);


-- ============================================================
-- 8. COUNTRY DIMENSION
-- ============================================================

WITH source_countries AS (
    SELECT country FROM silver.impressions
    UNION ALL
    SELECT country FROM silver.clicks
    UNION ALL
    SELECT country FROM silver.conversion_history
),
normalised AS (
    SELECT DISTINCT
        UPPER(NULLIF(BTRIM(country), '')) AS country_code
    FROM source_countries
)
INSERT INTO gold.dim_country (country_code)
SELECT country_code
FROM normalised
WHERE country_code IS NOT NULL
  AND country_code NOT IN ('N/A', 'NA', 'NULL', 'UNKNOWN', '-')
ON CONFLICT (country_code) DO NOTHING;


-- ============================================================
-- 9. DEVICE DIMENSION
-- ============================================================

WITH source_devices AS (
    SELECT device FROM silver.impressions
    UNION ALL
    SELECT device FROM silver.clicks
    UNION ALL
    SELECT device FROM silver.conversion_history
),
normalised AS (
    SELECT DISTINCT
        LOWER(NULLIF(BTRIM(device), '')) AS device_code
    FROM source_devices
)
INSERT INTO gold.dim_device (
    device_code, device_name
)
SELECT
    device_code,
    INITCAP(device_code)
FROM normalised
WHERE device_code IS NOT NULL
  AND device_code NOT IN ('n/a', 'na', 'null', 'unknown', '-')
ON CONFLICT (device_code) DO NOTHING;


-- ============================================================
-- 10. CONVERSION STATUS DIMENSION
-- ============================================================

WITH source_statuses AS (
    SELECT DISTINCT
        NULLIF(LOWER(BTRIM(status_normalized)), '')
            AS normalised_status,

        NULLIF(LOWER(BTRIM(status_raw)), '')
            AS raw_status

    FROM silver.conversion_history
),
status_values AS (
    SELECT DISTINCT
        COALESCE(
            normalised_status,
            'UNMAPPED:' || COALESCE(raw_status, 'missing')
        ) AS status_code,

        normalised_status IS NOT NULL AS is_mapped,

        normalised_status
    FROM source_statuses
),
distinct_statuses AS (
    SELECT
        status_code,
        CASE
            WHEN BOOL_OR(is_mapped)
                THEN INITCAP(MAX(normalised_status))
            ELSE 'Unmapped source status'
        END AS status_name,

        CASE
            WHEN BOOL_OR(is_mapped)
                THEN BOOL_OR(normalised_status = 'approved')
            ELSE NULL
        END AS is_approved

    FROM status_values
    GROUP BY status_code
)
INSERT INTO gold.dim_conversion_status (
    status_code, status_name, is_approved
)
SELECT
    status_code, status_name, is_approved
FROM distinct_statuses

ON CONFLICT (status_code)
DO UPDATE SET
    status_name = EXCLUDED.status_name,
    is_approved = EXCLUDED.is_approved

WHERE (
    gold.dim_conversion_status.status_name,
    gold.dim_conversion_status.is_approved
) IS DISTINCT FROM (
    EXCLUDED.status_name,
    EXCLUDED.is_approved
);



-- ============================================================
-- 11. DIMENSION ROW-COUNT VERIFICATION
-- ============================================================

SELECT 'dim_date' AS dimension, COUNT(*) AS row_count
FROM gold.dim_date

UNION ALL
SELECT 'dim_account_manager', COUNT(*)
FROM gold.dim_account_manager

UNION ALL
SELECT 'dim_advertiser', COUNT(*)
FROM gold.dim_advertiser

UNION ALL
SELECT 'dim_partner', COUNT(*)
FROM gold.dim_partner

UNION ALL
SELECT 'dim_offer', COUNT(*)
FROM gold.dim_offer

UNION ALL
SELECT 'dim_campaign', COUNT(*)
FROM gold.dim_campaign

UNION ALL
SELECT 'dim_creative', COUNT(*)
FROM gold.dim_creative

UNION ALL
SELECT 'dim_country', COUNT(*)
FROM gold.dim_country

UNION ALL
SELECT 'dim_device', COUNT(*)
FROM gold.dim_device

UNION ALL
SELECT 'dim_conversion_status', COUNT(*)
FROM gold.dim_conversion_status

ORDER BY dimension;
