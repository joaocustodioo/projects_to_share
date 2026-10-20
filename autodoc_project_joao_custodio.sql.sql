
-- Task done by Joao Custodio
-- BigQuery Console: https://console.cloud.google.com/bigquery?hl=pt&project=autodoc-joao-custodio&ws=!1m8!1m7!12m5!1m3!1sautodoc-joao-custodio!2seurope-west4!3sb05cb0f8-6baf-46bc-be4d-68ea7c7bcbff!2e1!23sRECENT_RESOURCES

-- ------------------------------------------------------------------------------
-- 0. Helper tables
-- `autodoc-joao-custodio.autodoc.aux_clean_events`: the events without exact duplicate rows
-- `autodoc-joao-custodio.autodoc.aux_sessions`: one row per session, with a 1/0 flag for each funnel step reached
-- ------------------------------------------------------------------------------

-- Aux Clean Events
create or replace table `autodoc-joao-custodio.autodoc.aux_clean_events` as
select distinct cast(event_date as timestamp) as event_time, session as session_id, `user` as user_id, page_type, event_type, product
from `autodoc-joao-custodio.autodoc.autodoc_data`;


-- Aux Sessions
create or replace table `autodoc-joao-custodio.autodoc.aux_sessions` as
with numbered_events as (
    select *, row_number() over (partition by session_id order by event_time, case event_type when 'page_view' then 1 when 'add_to_cart' then 2 when 'order' then 3 end) as event_number
    from `autodoc-joao-custodio.autodoc.aux_clean_events`
),
heavy_users as (
    select user_id from `autodoc-joao-custodio.autodoc.aux_clean_events` group by user_id having count(distinct session_id) >= 10
),
session_rows as (
    select
        session_id,
        min(user_id) as user_id,
        date(min(event_time)) as session_day,
        count(*) as events_in_session,
        max(case when event_number = 1 then page_type end) as first_page,
        max(case when page_type in ('listing_page', 'search_listing_page') and event_type = 'page_view' then 1 else 0 end) as reached_browse,
        max(case when page_type = 'product_page' and event_type = 'page_view' then 1 else 0 end) as reached_product,
        max(case when event_type = 'add_to_cart' then 1 else 0 end) as reached_cart,
        max(case when event_type = 'order' then 1 else 0 end) as reached_order,
        min(case when page_type = 'product_page' and event_type = 'page_view' then event_time end) as first_product_view_time,
        min(case when event_type = 'add_to_cart' then event_time end) as first_cart_time,
        min(case when event_type = 'order' then event_time end) as first_order_time
    from numbered_events
    group by session_id
)


-- outlier = 50+ events in a session, or a user with 10+ sessions
select *, case when events_in_session >= 50 or user_id in (select user_id from heavy_users) then 1 else 0 end as is_outlier
from session_rows;

-- ------------------------------------------------------------------------------
-- 0b. Data quality: rows, users, sessions, date range, nulls and duplicates in the raw table
-- ------------------------------------------------------------------------------

select
    count(*) as rows_in_table,
    count(distinct session) as sessions,
    count(distinct `user`) as users,
    min(event_date) as first_event,
    max(event_date) as last_event,
    countif(event_date is null or session is null or `user` is null or page_type is null or event_type is null or product is null) as rows_with_nulls,
    count(*) - (select count(*) from `autodoc-joao-custodio.autodoc.aux_clean_events`) as duplicate_rows_removed
from `autodoc-joao-custodio.autodoc.autodoc_data`;

-- ------------------------------------------------------------------------------
-- 0c. Outliers: how many sessions are removed before the analysis
-- Outlier = a session with 50 or more events, or any session of a user with 10 or more sessions.
-- Every block below this one leaves outliers out, except 4.2 (it is how outliers are found).
-- ------------------------------------------------------------------------------

select
    count(*) as all_sessions,
    sum(is_outlier) as outlier_sessions,
    round(100.0 * sum(is_outlier) / count(*), 2) as pct_outlier_sessions,
    count(*) - sum(is_outlier) as sessions_analysed,
    round(1.0 * count(*) / count(distinct user_id), 2) as avg_sessions_per_user_before_removal
from `autodoc-joao-custodio.autodoc.aux_sessions`;


-- ------------------------------------------------------------------------------
-- 1. Main metrics: by first page_type (outliers left out)
-- Same metrics and definitions as the block above, one row for the total and one for each first page_type.
-- Sessions that start on order_page count as purchases by definition, so read that row separately.
-- ------------------------------------------------------------------------------

with scoped as (
    select first_page as page_group, * from `autodoc-joao-custodio.autodoc.aux_sessions` where is_outlier = 0
    union all
    select 'Total' as page_group, * from `autodoc-joao-custodio.autodoc.aux_sessions` where is_outlier = 0
)
select
    page_group,
    count(*) as sessions,
    round(100.0 * sum(reached_browse) / count(*), 2) as browse_rate,
    round(100.0 * sum(reached_product) / count(*), 2) as product_view_rate,
    round(100.0 * sum(reached_cart) / sum(reached_product), 2) as product_to_cart,
    round(100.0 * sum(reached_cart * reached_order) / sum(reached_cart), 2) as cart_to_order,
    round(100.0 * sum(reached_cart * (1 - reached_order)) / sum(reached_cart), 2) as cart_abandonment,
    round(100.0 * sum(reached_order * (1 - reached_cart)) / sum(reached_order), 2) as orders_without_cart_event,
    round(100.0 * sum(reached_order) / count(*), 2) as conversion_pct,
    round(100.0 * sum(case when events_in_session = 1 then 1 else 0 end) / count(*), 1) as single_event_share
from scoped
group by page_group
order by case when page_group = 'Total' then 0 else 1 end, sessions desc;


-- ------------------------------------------------------------------------------
-- 2. Funnel: data behind the filters and KPIs (sessions by day and first page, outliers left out)
-- Data behind the filters, KPIs, funnel and journey.
-- Columns used in the dashboard: sessions, browsed, saw_product, carted, ordered, cart_and_order, single_event
-- ------------------------------------------------------------------------------

select
    session_day,
    first_page,
    count(*) as sessions,
    sum(reached_browse) as browsed,
    sum(reached_product) as saw_product,
    sum(reached_cart) as carted,
    sum(reached_order) as ordered,
    sum(reached_cart * reached_order) as cart_and_order,
    sum(case when events_in_session = 1 then 1 else 0 end) as single_event
from `autodoc-joao-custodio.autodoc.aux_sessions`
where is_outlier = 0
group by session_day, first_page
order by session_day, first_page;

-- ------------------------------------------------------------------------------
-- 2. Funnel: how many sessions and users reach each step, with step conversion and drop-off
-- Outliers left out.
-- Step conversion: Browse and See a product are measured against all visits (41% of sessions never browse and go straight to product pages).
-- Add to cart is measured against sessions that saw a product. Order is measured against sessions with a cart that ordered.
-- The funnel is not strictly nested: some sessions have an order without an add_to_cart event (see the metrics block).
-- ------------------------------------------------------------------------------

with totals as (
    select
        count(*) as visits,
        sum(reached_browse) as browsed,
        sum(reached_product) as saw_product,
        sum(reached_cart) as carted,
        sum(reached_order) as ordered,
        sum(reached_cart * reached_order) as cart_and_order,
        count(distinct user_id) as users,
        count(distinct if(reached_browse = 1, user_id, null)) as users_browsed,
        count(distinct if(reached_product = 1, user_id, null)) as users_saw_product,
        count(distinct if(reached_cart = 1, user_id, null)) as users_carted,
        count(distinct if(reached_order = 1, user_id, null)) as users_ordered
    from `autodoc-joao-custodio.autodoc.aux_sessions`
    where is_outlier = 0
),
steps as (
    select 1 as step_number, '1. Visit' as step, visits as sessions, users, cast(null as float64) as pct_of_previous_step, '' as compared_with from totals
    union all
    select 2, '2. Browse (listing or search)', browsed, users_browsed, 100.0 * browsed / visits, 'visits' from totals
    union all
    select 3, '3. See a product', saw_product, users_saw_product, 100.0 * saw_product / visits, 'visits' from totals
    union all
    select 4, '4. Add to cart', carted, users_carted, 100.0 * carted / saw_product, 'sessions that saw a product' from totals
    union all
    select 5, '5. Order', ordered, users_ordered, 100.0 * cart_and_order / carted, 'sessions with a cart that ordered' from totals
)
select
    step,
    sessions,
    users,
    round(100.0 * sessions / (select visits from totals), 2) as pct_of_visits,
    round(pct_of_previous_step, 2) as pct_of_previous_step,
    round(100.0 - pct_of_previous_step, 2) as drop_off_pct,
    compared_with
from steps
order by step_number;

-- ------------------------------------------------------------------------------
-- 2. Funnel, stage 1: Visit
-- Stage 1, Visit: how many people, and how deep do they go? (outliers left out)
-- ------------------------------------------------------------------------------

select
    count(*) as sessions,
    count(distinct user_id) as users,
    round(1.0 * count(*) / count(distinct user_id), 2) as sessions_per_user,
    round(100.0 * sum(case when events_in_session = 1 then 1 else 0 end) / count(*), 1) as pct_single_event,
    round(avg(events_in_session), 2) as avg_events_per_session
from `autodoc-joao-custodio.autodoc.aux_sessions`
where is_outlier = 0;

-- ------------------------------------------------------------------------------
-- 2. Funnel, stage 2: Browse
-- Stage 2, Browse: listing, search or both, and what happens next (outliers left out)
-- ------------------------------------------------------------------------------

with browsing as (
    select session_id,
           max(case when page_type = 'listing_page' then 1 else 0 end) as used_listing,
           max(case when page_type = 'search_listing_page' then 1 else 0 end) as used_search
    from `autodoc-joao-custodio.autodoc.aux_clean_events`
    where event_type = 'page_view' and session_id in (select session_id from `autodoc-joao-custodio.autodoc.aux_sessions` where is_outlier = 0)
    group by session_id
)
select
    case when used_listing = 1 and used_search = 1 then 'Both listing and search'
         when used_listing = 1 then 'Listing only'
         when used_search = 1 then 'Search only'
         else 'Product page only (no browse)' end as what_the_session_browsed,
    count(*) as sessions,
    round(100.0 * sum(reached_product) / count(*), 2) as pct_see_product,
    round(100.0 * sum(reached_cart) / count(*), 2) as pct_add_to_cart,
    round(100.0 * sum(reached_order) / count(*), 2) as pct_order
from browsing
join `autodoc-joao-custodio.autodoc.aux_sessions` using (session_id)
group by what_the_session_browsed
order by sessions desc;

-- ------------------------------------------------------------------------------
-- 2. Funnel, stage 3: See a product
-- Stage 3, See a product: does looking at more products help? (outliers left out)
-- ------------------------------------------------------------------------------

with product_pages_per_session as (
    select session_id, count(*) as product_pages_viewed
    from `autodoc-joao-custodio.autodoc.aux_clean_events`
    where page_type = 'product_page' and event_type = 'page_view' and session_id in (select session_id from `autodoc-joao-custodio.autodoc.aux_sessions` where is_outlier = 0)
    group by session_id
)
select
    case when product_pages_viewed = 1 then '1' when product_pages_viewed = 2 then '2' when product_pages_viewed <= 4 then '3 to 4' else '5 or more' end as product_pages_group,
    count(*) as sessions,
    round(100.0 * count(*) / sum(count(*)) over (), 1) as pct_of_product_sessions,
    round(100.0 * sum(reached_cart) / count(*), 2) as pct_add_to_cart,
    round(100.0 * sum(reached_order) / count(*), 2) as pct_order
from product_pages_per_session
join `autodoc-joao-custodio.autodoc.aux_sessions` using (session_id)
group by product_pages_group
order by min(product_pages_viewed);

-- ------------------------------------------------------------------------------
-- 2. Funnel, stage 4: Add to cart, by page
-- Stage 4, Add to cart: on which page does it happen? (outliers left out)
-- ------------------------------------------------------------------------------

select page_type, count(*) as cart_events, count(distinct session_id) as sessions, count(distinct product) as different_products
from `autodoc-joao-custodio.autodoc.aux_clean_events`
where event_type = 'add_to_cart' and session_id in (select session_id from `autodoc-joao-custodio.autodoc.aux_sessions` where is_outlier = 0)
group by page_type
order by cart_events desc;

-- ------------------------------------------------------------------------------
-- 2. Funnel, stage 4: Add to cart, by product
-- Stage 4, Add to cart: is it concentrated in a few products? (outliers left out)
-- ------------------------------------------------------------------------------

with cart_events_per_product as (
    select product, count(*) as cart_events, row_number() over (order by count(*) desc) as product_rank
    from `autodoc-joao-custodio.autodoc.aux_clean_events`
    where event_type = 'add_to_cart' and session_id in (select session_id from `autodoc-joao-custodio.autodoc.aux_sessions` where is_outlier = 0)
    group by product
)
select
    count(*) as different_products,
    sum(cart_events) as cart_events,
    round(100.0 * sum(case when product_rank <= 10 then cart_events end) / sum(cart_events), 1) as pct_of_cart_events_in_top_10
from cart_events_per_product;

-- ------------------------------------------------------------------------------
-- 2. Funnel, stage 5: Order, how sessions end
-- Stage 5, Order: how do sessions with a cart or an order end? (outliers left out)
-- ------------------------------------------------------------------------------

select
    case when reached_cart = 1 and reached_order = 1 then 'Cart, then order'
         when reached_cart = 1 then 'Cart, no order (abandoned)'
         else 'Order with no cart event' end as how_it_ended,
    count(*) as sessions
from `autodoc-joao-custodio.autodoc.aux_sessions`
where is_outlier = 0 and (reached_cart = 1 or reached_order = 1)
group by how_it_ended
order by sessions desc;

-- ------------------------------------------------------------------------------
-- 2. Funnel, stage 5: Order, time to cart and order
-- Stage 5, Order: how long do buyers take? (sessions with a product view, a cart and an order)
-- ------------------------------------------------------------------------------

select
    round(avg(timestamp_diff(first_cart_time, first_product_view_time, second) / 60.0), 1) as minutes_product_to_cart,
    round(avg(timestamp_diff(first_order_time, first_product_view_time, second) / 60.0), 1) as minutes_product_to_order
from `autodoc-joao-custodio.autodoc.aux_sessions`
where is_outlier = 0 and reached_order = 1 and first_product_view_time is not null and first_cart_time is not null;

-- ------------------------------------------------------------------------------
-- 3. Journey by first page_type
-- How the journey changes with the page the session started on (outliers left out)
-- ------------------------------------------------------------------------------

select
    first_page,
    count(*) as sessions,
    round(100.0 * count(*) / sum(count(*)) over (), 1) as pct_of_sessions,
    round(100.0 * sum(reached_product) / count(*), 2) as pct_see_product,
    round(100.0 * sum(reached_cart) / count(*), 2) as pct_add_to_cart,
    round(100.0 * sum(reached_order) / count(*), 2) as pct_order,
    round(100.0 * safe_divide(sum(reached_cart), sum(reached_product)), 2) as product_to_cart,
    round(100.0 * safe_divide(sum(reached_cart * reached_order), sum(reached_cart)), 2) as cart_to_order,
    round(100.0 * sum(case when events_in_session = 1 then 1 else 0 end) / count(*), 1) as pct_single_event
from `autodoc-joao-custodio.autodoc.aux_sessions`
where is_outlier = 0
group by first_page
order by sessions desc;




---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------------------------------------------------------------


-- ------------------------------------------------------------------------------
-- Part 2, question 1: customers per day whose first session only had product views (outliers left out)
-- Part 2, Q1: how many customers per day only viewed products in their first session?
-- "Only viewed products" = every event in that session is a product page view.
-- The first session is each user's earliest session. It is counted only if it is not an outlier.
-- We only see 14 days, so someone who first visited earlier can look new here.
-- ------------------------------------------------------------------------------

with sessions_of_user as (
    select user_id, session_id, min(event_time) as session_start,
           sum(case when page_type = 'product_page' and event_type = 'page_view' then 0 else 1 end) as other_events
    from `autodoc-joao-custodio.autodoc.aux_clean_events`
    group by user_id, session_id
),
first_sessions as (
    select *, row_number() over (partition by user_id order by session_start, session_id) as session_rank
    from sessions_of_user
)
select date(f.session_start) as first_session_day, count(*) as clients
from first_sessions f
join `autodoc-joao-custodio.autodoc.aux_sessions` s using (session_id)
where f.session_rank = 1 and f.other_events = 0 and s.is_outlier = 0   -- first session, only product page views, not an outlier
group by first_session_day
order by first_session_day;

-- ------------------------------------------------------------------------------
-- Part 2, question 2: abnormal behavior, one row per type of oddity
-- This block uses all sessions on purpose. It is how the outliers are found, so it cannot leave them out.
-- Part 2, Q2: abnormal behavior. One row per type of oddity.
-- ------------------------------------------------------------------------------

with per_session as (
    select session_id, count(*) as events,
           sum(case when event_type = 'order' then 1 else 0 end) as orders,
           sum(case when event_type = 'add_to_cart' then 1 else 0 end) as carts
    from `autodoc-joao-custodio.autodoc.aux_clean_events`
    group by session_id
),
per_user as (
    select user_id, count(distinct session_id) as sessions from `autodoc-joao-custodio.autodoc.aux_clean_events` group by user_id
)

select * from (
-- A. 50+ events in one session: not human, probably a bot
select 'A. Sessions with 50+ events' as anomaly, count(*) as how_many, max(events) as biggest_case from per_session where events >= 50
-- B. 10+ sessions for one user in 14 days (the 99th percentile is 4)
union all
select 'B. Users with 10+ sessions', count(*), max(sessions) from per_user where sessions >= 10
-- C. More than one order in a session
union all
select 'C. Sessions with 2+ orders', count(*), max(orders) from per_session where orders > 1
-- D. An order with no add to cart
union all
select 'D. Orders with no cart event', count(*), null from per_session where orders > 0 and carts = 0
-- E. Add to cart outside a product page
union all
select 'E. Add to cart outside a product page', count(distinct session_id), null from `autodoc-joao-custodio.autodoc.aux_clean_events` where event_type = 'add_to_cart' and page_type <> 'product_page'
-- F. Session starting on the order page
union all
select 'F. Sessions starting on the order page', count(*), null from `autodoc-joao-custodio.autodoc.aux_sessions` where first_page = 'order_page'
-- G. Same event logged more than once (raw table)
union all
select 'G. Events logged twice or more', count(*), max(copies)
from (
    select count(*) as copies from `autodoc-joao-custodio.autodoc.autodoc_data` group by event_date, session, `user`, page_type, event_type, product having count(*) > 1
))
order by anomaly;


