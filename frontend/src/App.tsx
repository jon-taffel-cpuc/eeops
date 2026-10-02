import type { ComponentType } from 'react';
import { Navigate, Route, Routes } from 'react-router';
import Layout from './components/Layout';
import { DEFAULT_PATH, NAV, type PageKey } from './nav';
import CustomersMarkets from './pages/CustomersMarkets';
import ExAnteCustom from './pages/ExAnteCustom';
import ProgramsPerformance from './pages/ProgramsPerformance';
import GridDetails from './pages/GridDetails';
import PoliciesProceedings from './pages/PoliciesProceedings';
import CpucAdmin from './pages/CpucAdmin';
import NotFound from './pages/NotFound';

// Page component for every key in nav.ts. TypeScript fails the build if a
// nav entry has no page here (or vice versa).
const PAGES: Record<PageKey, ComponentType> = {
  'customers-markets': CustomersMarkets,
  'ex-ante-custom': ExAnteCustom,
  'programs-performance': ProgramsPerformance,
  'grid-details': GridDetails,
  'policies-proceedings': PoliciesProceedings,
  'cpuc-admin': CpucAdmin,
};

export default function App() {
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Navigate to={DEFAULT_PATH} replace />} />
        {NAV.map(({ key, path }) => {
          const Page = PAGES[key];
          // "/*" lets a page add its own nested sub-routes later.
          return <Route key={key} path={`${path}/*`} element={<Page />} />;
        })}
        <Route path="*" element={<NotFound />} />
      </Routes>
    </Layout>
  );
}
